#include "bow_compressor.h"
#include "kernel_common.h"
#include <math.h>
#include <string.h>

void bow_chromatic_compressor_init(bow_chromatic_compressor_t *s, double sr)
{
    memset(s, 0, sizeof(*s));
    s->ratio = 1;
    s->voiceRatio = 0.5;
    s->floor = 0.01;
    s->detectorRelease = kc_onepole_tau_sr(0.050, sr);
    s->attack = kc_onepole_tau_sr(0.005, sr);
    s->release = kc_onepole_tau_sr(0.250, sr);
}

void bow_chromatic_compressor_set(bow_chromatic_compressor_t *s,
                                 double ratio, double voiceRatio, double floorDB)
{
    if (isfinite(ratio)) s->ratio = fmin(20, fmax(1, ratio));
    if (isfinite(voiceRatio)) s->voiceRatio = fmin(2, fmax(0.1, voiceRatio));
    if (isfinite(floorDB)) s->floor = pow(10, fmin(0, fmax(-80, floorDB)) / 20);
}

double bow_chromatic_compressor_gain(bow_chromatic_compressor_t *s,
                                    double mid, double side, double voiceEnvelope)
{
    if (s->ratio == 1 && s->reductionDB == 0) return 1;
    /* max(|L|, |R|) = |mid| + |side|: neither stereo channel escapes. */
    const double peak = fabs(mid) + fabs(side);
    s->envelope = peak > s->envelope ? peak
        : s->envelope + s->detectorRelease * (peak - s->envelope);
    const double threshold = fmax(s->floor, voiceEnvelope * s->voiceRatio);
    double target = 0;
    if (s->ratio > 1 && s->envelope > threshold * 0.7079457843841379) {
        const double overDB = 20 * log10(s->envelope / threshold);
        /* Six-dB soft knee, unity below it, attenuation only above it. */
        const double knee = overDB < 3 ? (overDB + 3) * (overDB + 3) / 12 : overDB;
        target = (1 - 1 / s->ratio) * knee;
    }
    const double a = target > s->reductionDB ? s->attack : s->release;
    s->reductionDB += a * (target - s->reductionDB);
    if (target == 0 && s->reductionDB < 1e-8) {
        s->reductionDB = 0;
        if (s->ratio == 1) s->envelope = 0;
    }
    return s->reductionDB == 0 ? 1 : pow(10, -s->reductionDB / 20);
}
