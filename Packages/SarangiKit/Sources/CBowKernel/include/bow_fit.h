#ifndef BOW_FIT_H
#define BOW_FIT_H
/* Shared fitted observation: causal minimum-phase timbre and synthetic room.
   Construction owns storage; setters/process/reset perform no allocations. */
void *bow_fit_create(const double *coefficients, const double *body_db,
                     const double *body_knots, const float *room, int room_frames,
                     const double *modes, int mode_count, double force_gain);
void bow_fit_destroy(void *state);
void bow_fit_reset(void *state);
/* timbre, response, memory, smoothing-ms, room, low/mid/high dB, ring, shelf dB */
void bow_fit_set(void *state, int control, double value);
void bow_fit_process(void *state, double *mid, double *side, const double *force,
                     int frames, const double *hz, const double *speed,
                     const double *load, const double *position, const double *gate,
                     int stride, int slots);
/* Independent coefficient/response verification, also used by contract tests. */
void bow_fit_curve(void *state, const double *raw_controls, double gate, double *db);
void bow_fit_impulse(void *state, double *impulse);
#endif
