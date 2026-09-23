#ifndef BOW_CONTACT_H
#define BOW_CONTACT_H
/* Build-time allocation; render, input and pluck are worker-owned, allocation-free.
   Modes are mass-normalized per linear density; q is displacement, p velocity.
   Drive tap includes 1/mu so input is newtons. */
void *bow_contact_create(int m,int j,double rate,double kc,double alpha,double hc,
    double weight,double rad,double pin,const double *omega,const double *sigma,
    const double *phi,const double *bone,const double *q,const double *p);
void bow_contact_destroy(void *ptr);
/* Construction only, before configuring excitation or rendering. Factor the
   supplied geometry through at most six components if relative Frobenius error
   is <= 1e-10 and projection work decreases. Returns the rank, or 0 with the
   dense geometry unchanged. Repeated calls retain the selected factorization. */
int bow_contact_compress(void *ptr);
/* Construction only, before excitation or rendering: 0 = Newton (default),
   1 = corrected scalar auxiliary energy. Returns 1 on success, 0 if refused.
   SAV uses aggregate contact loss and a passive energy cap; its energy audit
   reports modified energy and includes the cap's numerical dissipation. */
int bow_contact_set_sav(void *ptr,int enabled);
/* Worker-owned, one-way opt-out from diagnostic energy bookkeeping (on by
   default). Motion and solve diagnostics are unchanged; energy output and
   stats[3...7] become NaN rather than reporting an incomplete balance. */
void bow_contact_disable_energy_audit(void *ptr);
void bow_contact_release(void *ptr,double seconds,double force,const double *tap);
void bow_contact_radiation(void *ptr,const double *pin);
void bow_contact_drive(void *ptr,const double *tap,const double *normal_pin);
void bow_contact_input(void *ptr,double force);
double bow_contact_normal(void *ptr);
void bow_contact_pluck(void *ptr,double displacement,double pull,double release,const double *tap);
void bow_contact_state(void *ptr,double *q,double *p);
void bow_contact_damp(void *ptr,double multiplier);
int bow_contact_render(void *ptr,int n,double *out,double *energy,double *stats);
int bow_contact_render_audio(void *ptr,int n,double *out,double *stats);
#endif
