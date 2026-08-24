#ifndef TANPURA_KERNEL_H
#define TANPURA_KERNEL_H

/* TANPURA live kernel (2026-08-01): the r7 tanpura model as a playable
   slot instrument — one slot per keyboard note, mounted+settled at
   engine build, plucked at note-on, auto-idling when silent. Physics =
   scripts/tanpura_tool.c semantics (modal rotation, implicit grid
   contact, x4 deep substep, contact-mediated polarization). Tables
   from Swift (TanpuraTables, LOCKSTEP with tanpura_model.build_tables
   via params/tanpura_live.json). All calls single-threaded except
   tanpura_render vs pluck/damp, which only flip per-slot flags and
   add displacement — call them from the render thread's MIDI hand-off
   (the engine serializes). */

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

/* build-time: settle slot onto the static wrap (n samples at the
   heavy-damping rotation), store the equilibrium as the slot's q0 */
void tanpura_settle(void *ctx, int slot, long n);

/* ---- FD continuum slots (round 20, the live hybrid): kc arrives
   PRE-DIVIDED by MU; steps_per_out = internal FD steps per 48 kHz
   output sample ---- */
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

/* ---- live pitch bend + note-off release (Tarabdaar 2026-08-05, the
   main-instrument glide law) ---- bend: retune a mounted modal slot
   by `ratio` vs its mount pitch — every mode's rotation angle is
   rescaled from the base tables (damping envelope preserved) and the
   SAV response tables refreshed; modes bent past the output Nyquist
   are silenced, not aliased (they re-grow from contact when bent
   back). release: extra broadband amplitude decay at `rate` 1/s
   (t60 = ln(1000)/rate) toward the settled wrap — the string stays
   seated on the bone; rate 0 restores the natural ring. A pluck
   clears the release. These two mutate directly — sync-path/
   single-thread contract like tanpura_pluck; the pool path MUST go
   through tanpura_event2 (applied by the dispatcher, serialized
   with rendering). */
void tanpura_bend(void *ctx, int slot, double ratio);
void tanpura_release(void *ctx, int slot, double rate);
/* pluck isolation + pluck drive (Tarabdaar 2026-08-15; STRING-BANK
   rework, same day). touch 0..1: stored per slot; at each pluck
   above 0, the ringing string MIGRATES to a history clone — a
   separate string with the full jawari simulation, frozen at its
   own pitch, its ring scaled by touch (1 = survives in full) — and
   the pluck lands on settled state (0 = legacy ride-the-ring). The
   kernel keeps the N most recently played strings (tanpura_set_poly,
   0..16, default 6); overflow evicts the OLDEST clone into its
   owner's linear ghost bank (full band; spectral-split above 2*f0
   only when the evictee shares the plucked slot, whose fresh
   fundamental replaces it in the same instant), poly 0 skips clones
   entirely (split-ghost handoff — no history strings). A releasing
   (note-off) string is never resurrected into the ghost. The pluck
   bundle sends op 6 (pre-pluck bend) rather than op 1: a pitch
   change migrates the old string BEFORE the primary retunes; glide
   bends (op 1) retune the primary only and never migrate. drive
   (clamped
   0.05..20, 1 = fitted, bit-exact): each subsequent pluck drives
   the string drive-times harder into the jawari while the slot's
   output gain rides 1/drive — contact engagement (mellow<->buzzy)
   decoupled from radiated level. Modal slots only (the FD path
   keeps its round-21 fdTouch instead). Same sync-path contract as
   bend/release; pool path rides ops 3/4. */
void tanpura_set_touch(void *ctx, int slot, double touch);
void tanpura_set_drive(void *ctx, int slot, double drive);
void tanpura_prepluck_bend(void *ctx, int slot, double ratio);
/* string-bank size: live history strings before ghost eviction
   (0..16; atomic store, callable any time from any thread) */
void tanpura_set_poly(void *ctx, int n);
/* generalized note event, SPSC like tanpura_event: op 0 = note
   (val = amp; < 0 damps, slot -1 damps all), op 1 = glide bend
   (val = ratio), op 2 = release (val = rate 1/s, 0 = held),
   op 3 = pluck touch (val 0..1), op 4 = pluck drive (val 0.05..20),
   op 6 = pre-pluck bend (val = ratio; migrates history first) */
void tanpura_event2(void *ctx, int slot, int op, double val);

/* render n mono samples, ADDING into out (caller zeros) — the SYNC
   path (tests/bench/serial fallback; deep budget 3) */
void tanpura_render(void *ctx, int n, double *out);

/* ---- ASYNC one-block-late pool (the jt live pattern, 2026-08-01):
   the audio callback never computes — it reads completed audio and
   enqueues the next block; a dispatcher + workers render slots in
   parallel with NO deep budget (every slot gets its full substeps —
   the sync path's budget-degradation clicks cannot happen). Constant
   one-block latency; overload fade-fills + counts an underrun. ---- */
void tanpura_set_threads(void *ctx, int nworkers);  /* build-time only */
int tanpura_pool_size(void *ctx);
/* note event, MIDI-thread-safe SPSC (pool path): amp < 0 damps the
   slot, slot -1 damps all */
void tanpura_event(void *ctx, int slot, double amp);
void tanpura_render_async(void *ctx, int n, double *out);
long tanpura_underruns(void *ctx);
long tanpura_reset_count(void *ctx);

#endif
