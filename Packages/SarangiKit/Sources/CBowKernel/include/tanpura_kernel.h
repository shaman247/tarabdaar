#ifndef TANPURA_KERNEL_H
#define TANPURA_KERNEL_H

/* TANPURA live kernel: one slot per mounted pitch, settled at build,
   plucked at note-on, auto-idling when quiet. THREADING: sync path
   (tanpura_render) — pluck/damp/bend/release/set_touch/set_drive/
   prepluck_bend mutate slots directly, so drain them on the render
   thread ahead of the render; pool path (tanpura_render_async) — ONLY
   tanpura_event/tanpura_event2 (SPSC, one producer) may touch a slot. */

void *tanpura_create(int nslots);
void tanpura_free(void *ctx);

void tanpura_mount(void *ctx, int slot, int M, int J,
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
                   int ramp_n);

/* build-time: settle the slot onto the static wrap (n internal
   samples) and store the equilibrium as q0. Off the audio thread. */
void tanpura_settle(void *ctx, int slot, long n);

/* ---- FD continuum slots (not mounted by TanpuraEngine); kc arrives
   PRE-DIVIDED by MU. set_oversample = internal steps per output
   sample, modal slots too. ---- */
void tanpura_set_oversample(void *ctx, int slot, int steps);
void tanpura_mount_fd(void *ctx, int slot, int N,
                      const double *b, const double *pshape,
                      double lam2, double muk, double s1h,
                      double A0, double B0, double kc, double alpha,
                      int o_i, int ramp_n, int steps_per_out,
                      double gain, double dt, double touch);
void tanpura_fd_set_state(void *ctx, int slot, const double *u0);
void tanpura_settle_fd(void *ctx, int slot, long n);

void tanpura_pluck(void *ctx, int slot, double amp);
void tanpura_damp(void *ctx, int slot);
int tanpura_active_count(void *ctx);
/* scope telemetry: a slot's output envelope (0 idle) — display only */
double tanpura_slot_env(void *ctx, int slot);

/* bend: retune a mounted modal slot by `ratio` vs its mount pitch
   (clamped 0.25..4; envelope preserved; modes past the output Nyquist
   silenced, not aliased). release: extra broadband decay at `rate` 1/s
   (t60 = ln(1000)/rate) toward the settled wrap; 0 = natural ring; a
   pluck clears it. Sync-path contract; pool path = ops 1/2. */
void tanpura_bend(void *ctx, int slot, double ratio);
void tanpura_release(void *ctx, int slot, double rate);
/* touch 0..1 (per slot): above 0 each pluck migrates the ringing
   string to a history clone (frozen pitch, ring scaled by touch) and
   lands on settled state; 0 = rides the ring. tanpura_set_poly (0..16,
   default 6) clones stay alive; overflow evicts the OLDEST into its
   owner's linear ghost bank; poly 0 = split-ghost handoff, no clones.
   Pluck bundles send op 6 (pre-pluck bend) so a pitch change migrates
   BEFORE the retune; glide bends (op 1) never migrate. drive
   (0.05..20; 1 = fitted, bit-exact): pluck drive-times harder with
   output gain 1/drive. Modal slots only; pool path = ops 3/4/6. */
void tanpura_set_touch(void *ctx, int slot, double touch);
void tanpura_set_drive(void *ctx, int slot, double drive);
void tanpura_prepluck_bend(void *ctx, int slot, double ratio);
/* string-bank size: live history strings before ghost eviction
   (0..16; atomic store, callable any time from any thread) */
void tanpura_set_poly(void *ctx, int n);
/* generalized note event (SPSC): op 0 note (amp; < 0 damps, slot -1
   all), 1 glide bend, 2 release (rate 1/s), 3 touch, 4 drive, 6 pre-pluck bend */
void tanpura_event2(void *ctx, int slot, int op, double val);

/* render n mono samples, ADDING into out — the SYNC path */
void tanpura_render(void *ctx, int n, double *out);

/* ---- ASYNC one-block-late pool: the callback reads completed audio
   and enqueues the next block; dispatcher + workers render in parallel.
   Overload fade-fills + counts an underrun. ---- */
void tanpura_set_threads(void *ctx, int nworkers);  /* build-time only */
int tanpura_pool_size(void *ctx);
/* note event (pool path): amp < 0 damps the slot, slot -1 damps all */
void tanpura_event(void *ctx, int slot, double amp);
void tanpura_render_async(void *ctx, int n, double *out);
long tanpura_underruns(void *ctx);
long tanpura_reset_count(void *ctx);

#endif
