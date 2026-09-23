/* Two-direction raga rows in the existing worker-owned taraf bank. */
#include "bow_poly_internal.h"
#include "bow_tonal.h"
#include "bow_radiation.h"
#define DUAL_FIR_MAX 2049
#define CONTACT_SUBSTEPS (BOW_JT_DUAL_CONTACT_RATE/48000)
#define AA_N 41
// scipy.signal.firwin(41, 0.5, window=("kaiser", 5)); 96 -> 48 kHz.
static const double aa[AA_N]={-7.1589709508864583e-19,-0.0010514587726751215,1.8542998243319002e-18,0.0025089668121477146,-3.4941452339509673e-18,-0.0048948343392875709,5.6064511623748102e-18,0.008556559002481404,-8.0910130944529949e-18,-0.013989973238435148,1.0781132014374602e-17,0.022023120574074611,-1.345967742289739e-17,-0.034340179881744919,1.5884600682954171e-17,0.055288283911857014,-1.78202070879486e-17,-0.10093019739773382,1.9069296838463634e-17,0.3167003456803007,0.50025873529803011,0.3167003456803007,1.9069296838463634e-17,-0.10093019739773382,-1.78202070879486e-17,0.055288283911857014,1.5884600682954171e-17,-0.034340179881744919,-1.345967742289739e-17,0.022023120574074611,1.0781132014374602e-17,-0.013989973238435148,-8.0910130944529949e-18,0.008556559002481404,5.6064511623748102e-18,-0.0048948343392875709,-3.4941452339509673e-18,0.0025089668121477146,1.8542998243319002e-18,-0.0010514587726751215,-7.1589709508864583e-19};
#define CLOCK_PHASES 256
#define INPUT_HISTORY 1024
#define OUTPUT_HISTORY 128
#define OUTPUT_TAPS 64
#define INPUT_TAPS_MAX 512

// Build-time polyphase windowed-sinc tables. Interpolating neighboring phases
// prevents the clock converter itself from quantizing pitch or motion.
static double bessel0(double x) {
    double sum=1,term=1;
    for(int k=1;k<40;k++) {term*=x*x/(4*k*k);sum+=term;if(term<sum*1e-16)break;}
    return sum;
}
static void clock_table(double *table,int taps,double cutoff,int direction) {
    double half=(taps-1)*.5,den=bessel0(8.6);
    for(int p=0;p<=CLOCK_PHASES;p++) {
        double sum=0,offset=direction*(double)p/CLOCK_PHASES;
        for(int k=0;k<taps;k++) {
            double x=k-half-offset,edge=x/(taps*.5+1);
            double window=bessel0(8.6*sqrt(fmax(0,1-edge*edge)))/den;
            double sinc=fabs(x)<1e-12?2*cutoff:sin(2*M_PI*cutoff*x)/(M_PI*x);
            sum+=(table[p*taps+k]=sinc*window);
        }
        for(int k=0;k<taps;k++)table[p*taps+k]/=sum;
    }
}
static double clock_read(const double *history,const double *table,int taps,double phase) {
    double pos=phase*CLOCK_PHASES;
    int p=(int)pos;if(p>=CLOCK_PHASES)p=CLOCK_PHASES-1;
    double f=pos-p,a=0,b=0,c=0,d=0;
    const double *h0=table+p*taps,*h1=h0+taps;
    int k=0;
    for(;k+3<taps;k+=4) {
        a+=(h0[k]+f*(h1[k]-h0[k]))*history[-k];
        b+=(h0[k+1]+f*(h1[k+1]-h0[k+1]))*history[-k-1];
        c+=(h0[k+2]+f*(h1[k+2]-h0[k+2]))*history[-k-2];
        d+=(h0[k+3]+f*(h1[k+3]-h0[k+3]))*history[-k-3];
    }
    double y=(a+b)+(c+d);
    for(;k<taps;k++)y+=(h0[k]+f*(h1[k]-h0[k]))*history[-k];
    return y;
}

typedef struct {
    void *contact;
    int modes,aa_index,asleep,failed;
    double gain,force_scale,norm,tap[128];
    double aa_audio[AA_N],aa_force[AA_N],lp_audio,lp_force,last_audio,last_force;
    double rest[128],q[128],p[128];
    int primed,input_index,output_index,input_taps;
    double ratio,phase,damp_cached,damp_step;
    double drive_power,drive_memory,bloom;
    double pluck_level,pluck_mix,pluck_gain;
    _Atomic double bloom_target;
    double input_history[2*INPUT_HISTORY];
    double output_audio[2*OUTPUT_HISTORY],output_force[2*OUTPUT_HISTORY];
    double input_table[(CLOCK_PHASES+1)*INPUT_TAPS_MAX];
    double output_table[(CLOCK_PHASES+1)*OUTPUT_TAPS];
    void *tone,*radiation;
    _Atomic double tone_target,selectivity_target;
    unsigned long ticks;
    _Atomic double gain_target,norm_target;
    _Atomic uint64_t request;
    _Atomic unsigned long rendered,failures,iterations;
} Dual;

int bow_poly_jt_dual_load(void *vst,int row,void *contact,const double *tap,
    int modes,double gain,double force_scale,double bank_norm,const double *fir,int taps,double fundamental_hz) {
    bow_poly_state_t *st=vst;
    if(!st || !contact || row<0 || row>=st->njt || (st->jtDual && st->jtDual[row]) || modes<1 || modes>128
       || !tap || !fir || taps<1 || taps>DUAL_FIR_MAX || st->jtPoolN>0 || st->jtAsync
       || !isfinite(fundamental_hz) || fundamental_hz<70 || fundamental_hz>1821
       || fabs(st->sr/st->jtDiv-96000)>1 || !isfinite(gain) || !isfinite(force_scale))return 0;
    if(!st->jtDual)st->jtDual=calloc(st->njt,sizeof(void *));
    if(!st->jtDual)return 0;
    Dual *d=calloc(1,sizeof(*d));if(!d)return 0;
    d->ratio=fundamental_hz/561;
    d->pluck_gain=fmin(8,fmax(1,3.5/sqrt(d->ratio)));
    double input_band=fmin(1,.5*CONTACT_SUBSTEPS*d->ratio);
    d->input_taps=(int)ceil(64/input_band);
    if(d->input_taps>INPUT_TAPS_MAX)d->input_taps=INPUT_TAPS_MAX;
    clock_table(d->input_table,d->input_taps,.46*input_band,1);
    clock_table(d->output_table,OUTPUT_TAPS,.46*fmin(1,2/d->ratio),-1);
    d->damp_cached=d->damp_step=1;
    d->contact=contact;d->modes=modes;d->gain=gain;d->force_scale=force_scale;d->norm=bank_norm;
    atomic_init(&d->gain_target,gain);atomic_init(&d->norm_target,bank_norm);
    memcpy(d->tap,tap,sizeof(double)*modes);
    bow_contact_state(contact,d->rest,d->p);d->asleep=1;
    d->tone=bow_tonal_create(fundamental_hz);
    if(!d->tone) {free(d);return 0;}
    d->radiation=bow_radiation_create(fir,taps);
    if(!d->radiation) {bow_tonal_destroy(d->tone);free(d);return 0;}
    bow_contact_disable_energy_audit(contact);
    atomic_init(&d->tone_target,20000);
    atomic_init(&d->bloom_target,0);
    atomic_init(&d->selectivity_target,0);
    atomic_init(&d->request,0);atomic_init(&d->rendered,0);
    atomic_init(&d->failures,0);atomic_init(&d->iterations,0);
    st->jtDual[row]=d;st->jtDualCount++;st->jtGateSlp[row]=1;
    return 1;
}
void jt_dual_free(void *ptr) {
    Dual *d=ptr;if(!d)return;
    bow_contact_destroy(d->contact);bow_tonal_destroy(d->tone);bow_radiation_destroy(d->radiation);free(d);
}
double jt_dual_cost(void *ptr) {
    const Dual *d=ptr;
    // Converter overhead plus pitch-scaled contact/radiation work, relative
    // to a 64-mode chromatic row. Used only when constructing the worker plan.
    return .1+d->ratio;
}
int bow_poly_jt_dual_pluck(void *vst,int row,double displacement) {
    bow_poly_state_t *st=vst;
    if(!st || !st->jtDual || row<0 || row>=st->njt || !st->jtDual[row])return 0;
    if(!isfinite(displacement) || displacement<=0)return 1;
    Dual *d=st->jtDual[row];
    uint64_t value=(uint64_t)llround(fmin(displacement,.001)*1e12);
    atomic_store_explicit(&d->request,value,memory_order_relaxed);
    return 1;
}
void bow_poly_jt_dual_stats(void *vst,double *out) {
    bow_poly_state_t *st=vst;
    out[0]=-1;out[1]=out[2]=out[3]=0;
    if(!st || !st->jtDual)return;
    for(int row=0;row<st->njt;row++) {
        Dual *d=st->jtDual[row];if(!d)continue;
        if(out[0]<0)out[0]=row;
        out[1]+=atomic_load_explicit(&d->failures,memory_order_relaxed);
        out[2]+=atomic_load_explicit(&d->rendered,memory_order_relaxed);
        out[3]=fmax(out[3],atomic_load_explicit(&d->iterations,memory_order_relaxed));
    }
}

double jt_dual_tick(bow_poly_state_t *st,int row,double drive,double *returned) {
    Dual *d=st->jtDual[row];
    // Follow incoming energy, not an oscillator or a synthetic pluck. New
    // excitation charges the row; sustained forcing recedes so contact can
    // redistribute its stored energy. A gap re-arms the response naturally.
    // Track even in bypass, keeping a live enable independent of stale state.
    d->drive_power+=(1-exp(-1/(96000.0*.02)))*(drive*drive-d->drive_power);
    double memory_rate=d->drive_power>d->drive_memory
        ? 1-exp(-1/(96000.0*2.1)) : 1-exp(-1/(96000.0*.06));
    d->drive_memory+=memory_rate*(d->drive_power-d->drive_memory);
    if(d->drive_power<1e-30 && d->drive_memory<1e-30)
        d->drive_power=d->drive_memory=0;
    double target=atomic_load_explicit(&d->bloom_target,memory_order_relaxed);
    d->bloom+=(1-exp(-1/(96000.0*.04)))*(target-d->bloom);
    if(fabs(target-d->bloom)<1e-12)d->bloom=target;
    if(d->bloom>0) {
        double fresh=fmax(0,1-d->drive_memory/(d->drive_power+1e-30));
        drive*=1-d->bloom*.97*(1-fresh*fresh);
    }
    uint64_t request=atomic_exchange_explicit(&d->request,0,memory_order_relaxed);
    if(request && !d->failed) {
        bow_contact_pluck(d->contact,request*1e-12,.008,.0004,d->tap);
        d->pluck_level=1;
        d->asleep=0;
    }
    if(fabs(drive)>1e-10 && !d->failed)d->asleep=0;
    d->input_history[d->input_index]=drive;
    d->input_history[d->input_index+INPUT_HISTORY]=drive;
    if(st->jtDampMul!=d->damp_cached) {
        d->damp_cached=st->jtDampMul;
        d->damp_step=pow(st->jtDampMul,2/(CONTACT_SUBSTEPS*d->ratio));
    }
    // The contact clock is 96 kHz and its radiation clock 48 kHz.
    // Their wall-clock speeds follow pitch; neither geometry nor dimensionless
    // timestep changes. Both crossings of the shared 96 kHz bus are bandlimited.
    d->phase+=d->ratio*.5;
    while(d->phase>=1) {
        d->phase-=1;
        double audio=0,force=0;
        for(int sub=0;sub<CONTACT_SUBSTEPS;sub++) {
            double ac=0,fc=0;
            if(!d->failed && !d->asleep) {
                double lag=(CONTACT_SUBSTEPS-.5-sub)/(.5*CONTACT_SUBSTEPS*d->ratio)+2*d->phase/d->ratio;
                int whole=(int)lag;
                double input=clock_read(d->input_history+INPUT_HISTORY+d->input_index-whole,
                    d->input_table,d->input_taps,lag-whole);
                bow_contact_input(d->contact,input);
                double raw=0,stats[8];
                int publish=sub==CONTACT_SUBSTEPS-1 && (d->ticks&255)==0;
                int ok=bow_contact_render_audio(d->contact,1,&raw,publish?stats:NULL);
                if(ok!=1 || !isfinite(raw)) {
                    d->failed=1;
                    atomic_fetch_add_explicit(&d->failures,1,memory_order_relaxed);
                } else {
                    if(publish)atomic_store_explicit(&d->iterations,(unsigned long)stats[0],memory_order_relaxed);
                    double normal=bow_contact_normal(d->contact);
                    if(!d->primed) {d->lp_audio=raw;d->lp_force=normal;d->primed=1;}
                    const double a=1-exp(-2*M_PI*8/BOW_JT_DUAL_CONTACT_RATE);
                    d->lp_audio+=a*(raw-d->lp_audio);d->lp_force+=a*(normal-d->lp_force);
                    ac=raw-d->lp_audio;fc=normal-d->lp_force;
                    bow_contact_damp(d->contact,d->damp_step);
                }
            }
            // Drain the anti-alias and radiation tails even after the row sleeps.
            d->aa_audio[d->aa_index]=ac;d->aa_force[d->aa_index]=fc;
            if(sub==CONTACT_SUBSTEPS-1)for(int k=0;k<AA_N;k++) {
                int index=(d->aa_index-k+AA_N)%AA_N;
                audio+=aa[k]*d->aa_audio[index];force+=aa[k]*d->aa_force[index];
            }
            d->aa_index=(d->aa_index+1)%AA_N;
        }
        if(d->failed) {audio=d->last_audio*.9958;force=d->last_force*.9958;}
        else if(d->asleep)force=d->last_force*exp(-2*M_PI*8/48000.0);
        d->last_audio=audio;d->last_force=force;
        double y=bow_radiation_tick(d->radiation,audio);
        d->output_index=(d->output_index+1)&(OUTPUT_HISTORY-1);
        d->output_audio[d->output_index]=d->output_audio[d->output_index+OUTPUT_HISTORY]=y;
        d->output_force[d->output_index]=d->output_force[d->output_index+OUTPUT_HISTORY]=force;
    }
    d->input_index=(d->input_index+1)&(INPUT_HISTORY-1);
    if(!d->asleep && !d->failed && (d->ticks&255)==0) {
        bow_contact_state(d->contact,d->q,d->p);
        int quiet=!request && fabs(drive)<1e-10;
        for(int k=0;k<d->modes;k++)
            if(fabs(d->q[k]-d->rest[k])>1e-11 || fabs(d->p[k])>1e-7)quiet=0;
        if(quiet)d->asleep=1;
        // Scope combines both directions in reference coordinates.
        if(st->scopeOn)for(int k=0;k<st->scopeK;k++) {
            double v=k<d->modes/2?hypot(d->p[k],d->p[k+d->modes/2]):0;
            st->scopeMode[row*st->scopeK+k]=(float)v;
        }
    }
    double y=clock_read(d->output_audio+OUTPUT_HISTORY+d->output_index,
        d->output_table,OUTPUT_TAPS,d->phase);
    double force=clock_read(d->output_force+OUTPUT_HISTORY+d->output_index,
        d->output_table,OUTPUT_TAPS,d->phase);
    d->ticks++;
    if((d->ticks&255)==0)atomic_store_explicit(&d->rendered,d->ticks,memory_order_relaxed);
    if(st->jtGateSlp[row]!=(unsigned char)d->asleep)st->jtGateSlp[row]=(unsigned char)d->asleep;
    const double slew=1-exp(-1/(96000.0*.04));
    d->gain+=slew*(atomic_load_explicit(&d->gain_target,memory_order_relaxed)-d->gain);
    d->norm+=slew*(atomic_load_explicit(&d->norm_target,memory_order_relaxed)-d->norm);
    *returned=force*d->force_scale*d->norm;
    // Only radiated sound enters the spectral filter, never physical feedback.
    y=bow_tonal_tick(d->tone,y,atomic_load_explicit(&d->tone_target,memory_order_relaxed),
        atomic_load_explicit(&d->selectivity_target,memory_order_relaxed));
    // Direct plucks need their own radiation calibration: increasing the
    // plectrum displacement changes contact timbre instead of just loudness.
    // Smooth retriggers on an already ringing row; relax toward sympathetic
    // level over the tail. This never enters the mechanical return above.
    if(d->pluck_level>0 || d->pluck_mix>0) {
        d->pluck_mix+=(1-exp(-1/(96000.0*.004)))*(d->pluck_level-d->pluck_mix);
        d->pluck_level*=exp(-1/(96000.0*2));
        if(d->pluck_level<1e-12 && d->pluck_mix<1e-12)
            d->pluck_level=d->pluck_mix=0;
        y*=1+(d->pluck_gain-1)*d->pluck_mix;
    }
    return y*d->gain;
}

void bow_poly_jt_dual_levels(void *vst,int row,double gain,double norm) {
    bow_poly_state_t *st=vst;
    Dual *d=st && st->jtDual && row>=0 && row<st->njt?st->jtDual[row]:NULL;
    if(!d || !isfinite(gain) || !isfinite(norm) || gain<0 || norm<0)return;
    atomic_store_explicit(&d->gain_target,gain,memory_order_relaxed);
    atomic_store_explicit(&d->norm_target,gain>1e-12?norm:0,memory_order_relaxed);
}

void bow_poly_jt_dual_tone(void *vst,double hz) {
    bow_poly_state_t *st=vst;
    if(!st || !st->jtDual || !isfinite(hz))return;
    hz=fmin(20000,fmax(2000,hz));
    for(int row=0;row<st->njt;row++) {
        Dual *d=st->jtDual[row];if(!d)continue;
        atomic_store_explicit(&d->tone_target,hz,memory_order_relaxed);
    }
}

void bow_poly_jt_dual_selectivity(void *vst,double value) {
    bow_poly_state_t *st=vst;
    if(!st || !st->jtDual || !isfinite(value))return;
    value=fmin(1,fmax(0,value));
    for(int row=0;row<st->njt;row++) {
        Dual *d=st->jtDual[row];if(!d)continue;
        atomic_store_explicit(&d->selectivity_target,value,memory_order_relaxed);
    }
}

void bow_poly_jt_dual_bloom(void *vst,double value) {
    bow_poly_state_t *st=vst;
    if(!st || !st->jtDual || !isfinite(value))return;
    value=fmin(1,fmax(0,value));
    for(int row=0;row<st->njt;row++) {
        Dual *d=st->jtDual[row];if(!d)continue;
        atomic_store_explicit(&d->bloom_target,value,memory_order_relaxed);
    }
}
