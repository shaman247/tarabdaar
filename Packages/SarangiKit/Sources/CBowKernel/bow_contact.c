/* Realtime exponential discrete-gradient contact integrator.
   Port of tools/experiments/taraf_sitar/physics_v3/contact.c; retain the
   offline implementation as an independent approved-render reference.
   Unit-normalized string modes, fixed unilateral bridge, no output shaping.
   Constant modal force is integrated exactly; the secant of contact potential
   makes its work cancel the change in stored contact energy. */
#include "bow_contact.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>
#define MM 128
#define JJ 48
#define CONTACT_RANK 6

typedef struct {
    int m,j,failed,max_iterations,audit;
    double dt,kc,alpha,hc,weight,rad,pin;
    double w[MM],q[MM],p[MM],c[MM],s[MM],a[MM],v[MM],damp[MM];
    double phi[MM*JJ],bone[JJ],G[JJ*JJ],GT[JJ*JJ],last[JJ];
    double energy_initial,max_relative_drift,max_residual;
    double external_work,dissipated;
    double release_time,release_force,tap[MM];
    double pin_vector[MM];
    long elapsed;
    int contact_count,contact_modes[MM];
    int contact_rank;
    double contact_u[MM*CONTACT_RANK],contact_v[CONTACT_RANK*JJ];
    double drive[MM],input,normal_pin[MM],normal_output;
    double pull_time,pull_amplitude,pull_start,pull_velocity,last_hold;
    double motor_a,motor_u[JJ],motor_G[JJ*JJ],motor_GT[JJ*JJ];
    int pulling;
    int sav,started;
    double sav_psi,sav_previous[JJ];
} Contact;

static double energy(Contact *s) {
    double e=0;
    for(int k=0;k<s->m;k++)e+=.5*(s->p[k]*s->p[k]+s->w[k]*s->w[k]*s->q[k]*s->q[k]);
    if(s->sav)return e+s->weight*.5*s->sav_psi*s->sav_psi;
    for(int j=0;j<s->j;j++){
        double eta=s->bone[j];
        for(int k=0;k<s->m;k++)eta-=s->phi[k*s->j+j]*s->q[k];
        if(eta>0)e+=s->weight*s->kc*pow(eta,s->alpha+1)/(s->alpha+1);
    }
    return e;
}

#include "bow_contact_sav.inc"

/* Stable divided difference; integral formula near coincident arguments.
   Its derivative is with respect to the second penetration. */
static void force(Contact *s,double x,double y,double vx,double *f,double *df) {
    double d=y-x,mid=.5*(x+y),scale=fmax(fmax(fabs(x),fabs(y)),1e-15);
    double value,derivative;
    if(x<=0 && y<=0){*f=0;*df=0;return;}
    if(fabs(d)<1e-5*scale && mid>0){
        // Newton starts at the old endpoint, whose potential is already cached.
        // Retain pow for subnormal/zero potentials so division cannot lose it.
        double pa=d==0 && isnormal(vx)?vx/mid:pow(mid,s->alpha);
        double correction=s->alpha*(s->alpha-1)*d*d/(24*mid*mid);
        value=s->kc*pa*(1+correction);
        derivative=s->kc*s->alpha*pa/(2*mid);
    }else{
        double vy=y>0?pow(y,s->alpha+1):0;
        value=s->kc/(s->alpha+1)*(vy-vx)/d;
        // Reuse y^(alpha+1) for its derivative instead of a second power call.
        derivative=((y>0?s->kc*(isnormal(vy)?vy/y:pow(y,s->alpha)):0)-value)/d;
    }
    double factor=1+s->hc*d/s->dt;
    if(factor<=0){*f=0;*df=0;return;}
    *f=value*factor;
    *df=derivative*factor+value*s->hc/s->dt;
}

static int linear(int n,double *a,double *b) {
    for(int k=0;k<n;k++){
        int pivot=k;
        for(int i=k+1;i<n;i++)if(fabs(a[i*n+k])>fabs(a[pivot*n+k]))pivot=i;
        if(fabs(a[pivot*n+k])<1e-25)return 0;
        if(pivot!=k){
            for(int j=k;j<n;j++){double v=a[k*n+j];a[k*n+j]=a[pivot*n+j];a[pivot*n+j]=v;}
            double v=b[k];b[k]=b[pivot];b[pivot]=v;
        }
        for(int i=k+1;i<n;i++){
            double v=a[i*n+k]/a[k*n+k];
            for(int j=k+1;j<n;j++)a[i*n+j]-=v*a[k*n+j];
            b[i]-=v*b[k];
        }
    }
    for(int i=n-1;i>=0;i--){for(int j=i+1;j<n;j++)b[i]-=a[i*n+j]*b[j];b[i]/=a[i*n+i];}
    return 1;
}

static double residual(Contact *s,const double *old,const double *oldPotential,const double *eta,const double *star,double *f,double *df,double *r){
    int jn=s->j;double norm=0;int active[JJ],count=0;
    for(int j=0;j<jn;j++) {
        force(s,old[j],eta[j],oldPotential[j],f+j,df+j);
        if(f[j]!=0)active[count++]=j;
    }
    for(int j=0;j<jn;j++)r[j]=eta[j]-star[j];
    const double *transpose=s->pulling?s->motor_GT:s->GT;
    // SIMD across contact sites, retaining the force addition order at each.
    for(int a=0;a<count;a++) {
        int l=active[a];const double *g=transpose+l*jn;
        for(int j=0;j<jn;j++)r[j]+=g[j]*f[l];
    }
    for(int j=0;j<jn;j++)norm=fmax(norm,fabs(r[j]));
    return norm;
}

void *bow_contact_create(int m,int j,double rate,double kc,double alpha,double hc,double weight,
                     double rad,double pin,const double *omega,const double *sigma,
                     const double *phi,const double *bone,const double *q,const double *p){
    if(m<1||m>MM||j<1||j>JJ||rate<=0)return NULL;
    Contact *s=calloc(1,sizeof(*s));if(!s)return NULL;s->m=m;s->j=j;s->dt=1/rate;s->audit=1;
    s->kc=kc;s->alpha=alpha;s->hc=hc;s->weight=weight;s->rad=rad;s->pin=pin;
    memcpy(s->phi,phi,sizeof(double)*m*j);memcpy(s->bone,bone,sizeof(double)*j);
    for(int k=0;k<m;k++){
        int active=0;
        for(int z=0;z<j;z++)if(phi[k*j+z]!=0)active=1;
        if(active)s->contact_modes[s->contact_count++]=k;
        double wd=omega[k]*s->dt;
        s->w[k]=omega[k];s->q[k]=q[k];s->p[k]=p[k];s->c[k]=cos(wd);s->s[k]=sin(wd);
        s->a[k]=2*pow(sin(.5*wd)/omega[k],2);s->v[k]=sin(wd)/omega[k];
        s->damp[k]=exp(-sigma[k]*s->dt);
        s->pin_vector[k]=pin*((k&1)?1:-1)*(k+1);
    }
    for(int i=0;i<j;i++)for(int l=0;l<j;l++)for(int k=0;k<m;k++)
        s->G[i*j+l]+=s->weight*phi[k*j+i]*s->a[k]*phi[k*j+l];
    for(int i=0;i<j;i++)for(int l=0;l<j;l++)s->GT[l*j+i]=s->G[i*j+l];
    s->energy_initial=energy(s);
    return s;
}

int bow_contact_set_sav(void *ptr,int enabled) {
    Contact *s=ptr;
    if(!s || s->started || (enabled!=0 && enabled!=1))return 0;
    s->sav=enabled;
    if(enabled)sav_initialize(s);
    s->energy_initial=energy(s);
    return 1;
}

int bow_contact_compress(void *ptr) {
    Contact *s=ptr;
    if(!s)return 0;
    if(s->contact_rank)return s->contact_rank;
    const int m=s->m,j=s->j;
    if(s->started || s->elapsed || s->pull_time || s->release_time || CONTACT_RANK*(m+j)>=m*j)return 0;
    // Pivoted, reorthogonalized Gram-Schmidt is construction-only. Never use
    // factors for a geometry whose measured reconstruction error is too large.
    double remainder[MM*JJ],u[MM*CONTACT_RANK]={0},v[CONTACT_RANK*JJ]={0};
    double total=0;
    memcpy(remainder,s->phi,sizeof(double)*m*j);
    for(int k=0;k<m*j;k++)total+=s->phi[k]*s->phi[k];
    if(!isfinite(total) || total<=0)return 0;
    int rank=0;
    for(int r=0;r<CONTACT_RANK;r++) {
        int pivot=0;double largest=0;
        for(int z=0;z<j;z++) {
            double norm=0;for(int k=0;k<m;k++)norm+=remainder[k*j+z]*remainder[k*j+z];
            if(norm>largest){largest=norm;pivot=z;}
        }
        if(largest<=total*1e-28)break;
        for(int k=0;k<m;k++)u[k*CONTACT_RANK+r]=remainder[k*j+pivot];
        for(int pass=0;pass<2;pass++)for(int a=0;a<r;a++) {
            double dot=0;for(int k=0;k<m;k++)dot+=u[k*CONTACT_RANK+a]*u[k*CONTACT_RANK+r];
            for(int k=0;k<m;k++)u[k*CONTACT_RANK+r]-=dot*u[k*CONTACT_RANK+a];
        }
        double norm=0;for(int k=0;k<m;k++)norm+=u[k*CONTACT_RANK+r]*u[k*CONTACT_RANK+r];
        if(!isfinite(norm) || norm<=total*1e-28)break;
        norm=sqrt(norm);
        for(int k=0;k<m;k++)u[k*CONTACT_RANK+r]/=norm;
        for(int z=0;z<j;z++) {
            double dot=0;for(int k=0;k<m;k++)dot+=u[k*CONTACT_RANK+r]*s->phi[k*j+z];
            v[r*j+z]=dot;
            for(int k=0;k<m;k++)remainder[k*j+z]-=u[k*CONTACT_RANK+r]*dot;
        }
        rank=r+1;
    }
    double reconstructed[MM*JJ],error=0;
    for(int k=0;k<m;k++)for(int z=0;z<j;z++) {
        double value=0;
        for(int r=0;r<CONTACT_RANK;r++)value+=u[k*CONTACT_RANK+r]*v[r*j+z];
        reconstructed[k*j+z]=value;
        double delta=value-s->phi[k*j+z];error+=delta*delta;
    }
    if(!rank || !isfinite(error) || error>total*1e-20)return 0;
    memcpy(s->contact_u,u,sizeof(u));memcpy(s->contact_v,v,sizeof(v));
    memcpy(s->phi,reconstructed,sizeof(double)*m*j);s->contact_rank=rank;
    s->contact_count=0;
    for(int k=0;k<m;k++) {
        int active=0;for(int z=0;z<j;z++)if(s->phi[k*j+z]!=0)active=1;
        if(active)s->contact_modes[s->contact_count++]=k;
    }
    // Rebuild both force/displacement directions from the same geometry so
    // discrete contact work remains reciprocal, including the plectrum solve.
    memset(s->G,0,sizeof(s->G));
    for(int i=0;i<j;i++)for(int l=0;l<j;l++)for(int k=0;k<m;k++)
        s->G[i*j+l]+=s->weight*s->phi[k*j+i]*s->a[k]*s->phi[k*j+l];
    for(int i=0;i<j;i++)for(int l=0;l<j;l++)s->GT[l*j+i]=s->G[i*j+l];
    if(s->sav)sav_initialize(s);
    s->energy_initial=energy(s);
    return rank;
}

void bow_contact_release(void *ptr,double seconds,double force_value,const double *tap){
    Contact *s=ptr;s->started=1;s->release_time=seconds;s->release_force=force_value;
    memcpy(s->tap,tap,sizeof(double)*s->m);s->elapsed=0;
}
void bow_contact_radiation(void *ptr,const double *pin_vector){
    Contact *s=ptr;memcpy(s->pin_vector,pin_vector,sizeof(double)*s->m);
}

int bow_contact_render(void *ptr,int n,double *out,double *energies,double *stats){
    Contact *s=ptr;int m=s->m,j=s->j;
    if(n>0)s->started=1;
    for(int frame=0;frame<n;frame++){
        double qs[MM],ps[MM],old[JJ],oldPotential[JJ],star[JJ],eta[JJ],f[JJ],df[JJ],r[JJ];
        double time=(s->elapsed+.5)*s->dt;
        double hold=time<s->release_time?s->release_force*.5*(1+cos(M_PI*time/s->release_time)):0;
        double load[MM];
        double lambda0=0;
        s->pulling=s->pull_time>0 && time<s->pull_time;
        if(!s->pulling && s->pull_time>0) {
            double release_t=time-s->pull_time;
            hold=release_t<s->release_time?s->last_hold*.5*(1+cos(M_PI*release_t/s->release_time)):0;
        }
        s->elapsed++;
        for(int k=0;k<m;k++){
            if(s->audit)s->dissipated+=.5*s->p[k]*s->p[k]*(1-s->damp[k]*s->damp[k]);
            s->p[k]*=s->damp[k];
            load[k]=s->tap[k]*hold+s->drive[k]*s->input;
            qs[k]=s->c[k]*s->q[k]+s->v[k]*s->p[k]+s->a[k]*load[k];
            ps[k]=-s->w[k]*s->s[k]*s->q[k]+s->c[k]*s->p[k]+s->v[k]*load[k];
        }
        if(s->pulling) {
            /* Position belongs to the END of this integration step. The
               release force uses midpoint time, but imposing a midpoint
               position here would brake a moving string on the first step. */
            double u=fmin(s->elapsed*s->dt/s->pull_time,1);
            // Hermite path starts at the current position AND velocity.
            double target=s->pull_start+s->pull_amplitude*u*u*(3-2*u)
                +s->pull_velocity*s->pull_time*u*(1-u)*(1-u);
            double free_position=0;
            for(int k=0;k<m;k++)free_position+=s->tap[k]*qs[k];
            lambda0=(target-free_position)/s->motor_a;
            for(int k=0;k<m;k++) {qs[k]+=s->a[k]*s->tap[k]*lambda0;ps[k]+=s->v[k]*s->tap[k]*lambda0;}
        }
        const double *compliance=s->pulling?s->motor_G:s->G;
        memcpy(old,s->bone,sizeof(double)*j);
        memcpy(star,s->bone,sizeof(double)*j);
        // Contiguous contact-site lanes vectorize without changing the
        // accumulation order of modes at any site (or the contact solve).
        if(s->contact_rank) {
            double projected_old[CONTACT_RANK]={0},projected_next[CONTACT_RANK]={0};
            for(int a=0;a<s->contact_count;a++) {
                int k=s->contact_modes[a];
                for(int r=0;r<CONTACT_RANK;r++) {
                    projected_old[r]+=s->contact_u[k*CONTACT_RANK+r]*s->q[k];
                    projected_next[r]+=s->contact_u[k*CONTACT_RANK+r]*qs[k];
                }
            }
            for(int r=0;r<CONTACT_RANK;r++)for(int z=0;z<j;z++) {
                old[z]-=s->contact_v[r*j+z]*projected_old[r];
                star[z]-=s->contact_v[r*j+z]*projected_next[r];
            }
        } else for(int a=0;a<s->contact_count;a++) {
            int k=s->contact_modes[a];
            const double *phi=s->phi+k*j;
            const double q=s->q[k],next=qs[k];
            for(int z=0;z<j;z++) {
                old[z]-=phi[z]*q;
                star[z]-=phi[z]*next;
            }
        }
        if(s->sav) {
            if(!sav_step(s,old,star,eta,f)){s->failed++;return frame;}
        } else {
            memcpy(eta,old,sizeof(double)*j);
            // The old endpoint is invariant throughout Newton and line search.
            // Cache its potential without changing any force arithmetic.
            for(int z=0;z<j;z++)oldPotential[z]=old[z]>0?pow(old[z],s->alpha+1):0;
            double norm=residual(s,old,oldPotential,eta,star,f,df,r);int iter=0;
            for(;iter<24 && norm>1e-13;iter++){
                double jac[JJ*JJ],delta[JJ],active_delta[JJ];int active[JJ],na=0;
                for(int z=0;z<j;z++)if(df[z]!=0)active[na++]=z;
                for(int z=0;z<na;z++){
                    active_delta[z]=-r[active[z]];
                    for(int l=0;l<na;l++)jac[z*na+l]=compliance[active[z]*j+active[l]]*df[active[l]]+(z==l);
                }
                if(!linear(na,jac,active_delta))break;
                for(int z=0;z<j;z++)delta[z]=-r[z];
                const double *transpose=s->pulling?s->motor_GT:s->GT;
                for(int l=0;l<na;l++) {
                    const double *g=transpose+active[l]*j;
                    for(int z=0;z<j;z++)delta[z]-=g[z]*df[active[l]]*active_delta[l];
                }
                for(int z=0;z<na;z++)delta[active[z]]=active_delta[z];
                int accepted=0;
                for(double step=1;step>=1.0/4096;step*=.5){
                    double next[JJ],nf[JJ],nd[JJ],nr[JJ];
                    for(int z=0;z<j;z++)next[z]=eta[z]+step*delta[z];
                    double nn=residual(s,old,oldPotential,next,star,nf,nd,nr);
                    if(nn<norm){
                        memcpy(eta,next,sizeof(double)*j);memcpy(f,nf,sizeof(double)*j);
                        memcpy(df,nd,sizeof(double)*j);memcpy(r,nr,sizeof(double)*j);
                        norm=nn;accepted=1;break;
                    }
                }
                if(!accepted)break;
            }
            if(iter>s->max_iterations)s->max_iterations=iter;
            s->max_residual=fmax(s->max_residual,norm);
            if(norm>1e-11||!isfinite(norm)){s->failed++;return frame;}
        }
        double correction=0;
        if(s->pulling) {
            for(int z=0;z<j;z++)correction-=s->motor_u[z]*f[z]*s->weight/s->motor_a;
            s->last_hold=lambda0+correction;
            for(int k=0;k<m;k++){
                qs[k]+=s->a[k]*s->tap[k]*correction;
                ps[k]+=s->v[k]*s->tap[k]*correction;
                load[k]+=s->tap[k]*s->last_hold;
            }
        }
        double sum=0,pin=0,normal=0;
        for(int z=0;z<j;z++)sum+=f[z];
        if(s->audit && !s->sav && s->hc!=0){
            double hc=s->hc;s->hc=0;
            for(int z=0;z<j;z++){
                double conservative,unused;force(s,old[z],eta[z],oldPotential[z],&conservative,&unused);
                s->dissipated+=s->weight*(f[z]-conservative)*(eta[z]-old[z]);
            }
            s->hc=hc;
        }
        double modal_force[MM]={0};
        int active_force[JJ],force_count=0;
        for(int z=0;z<j;z++)if(f[z]!=0)active_force[force_count++]=z;
        for(int a=0;a<s->contact_count;a++){
            int k=s->contact_modes[a];double modal=0;
            for(int v=0;v<force_count;v++) {
                int z=active_force[v];modal+=s->phi[k*j+z]*f[z]*s->weight;
            }
            modal_force[k]=modal;
        }
        for(int k=0;k<m;k++){
            double modal=modal_force[k];
            double next=qs[k]+s->a[k]*modal,velocity=ps[k]+s->v[k]*modal;
            if(s->audit) {
                s->external_work+=load[k]*(next-s->q[k]);
                s->dissipated+=.5*velocity*velocity*(1-s->damp[k]*s->damp[k]);
            }
            s->q[k]=next;s->p[k]=velocity*s->damp[k];
            pin+=s->pin_vector[k]*s->q[k];
            normal+=s->normal_pin[k]*s->q[k];
        }
        out[frame]=s->rad*sum+pin;
        s->normal_output=s->rad*sum+normal;
        if(energies)energies[frame]=s->audit?energy(s):NAN;
    }
    if(stats){
        stats[0]=s->max_iterations;stats[1]=s->max_residual;stats[2]=s->failed;
        if(s->audit) {
            stats[3]=s->energy_initial;stats[4]=s->external_work;stats[5]=s->dissipated;stats[6]=energy(s);
            stats[7]=stats[6]-stats[3]-stats[4]+stats[5];
        } else for(int k=3;k<8;k++)stats[k]=NAN;
    }
    return n;
}
int bow_contact_render_audio(void *ptr,int n,double *out,double *stats){return bow_contact_render(ptr,n,out,NULL,stats);}
void bow_contact_destroy(void *ptr){free(ptr);}
void bow_contact_disable_energy_audit(void *ptr){((Contact*)ptr)->audit=0;}

void bow_contact_drive(void *ptr,const double *tap,const double *normal_pin) {
    Contact *s=ptr;memcpy(s->drive,tap,sizeof(double)*s->m);
    memcpy(s->normal_pin,normal_pin,sizeof(double)*s->m);
}
void bow_contact_input(void *ptr,double force) {
    Contact *s=ptr;if(force!=0)s->started=1;s->input=force;
}
double bow_contact_normal(void *ptr) {return ((Contact*)ptr)->normal_output;}
void bow_contact_pluck(void *ptr,double displacement,double pull,double release,const double *tap) {
    Contact *s=ptr;
    s->started=1;
    s->pull_time=pull;s->release_time=release;s->pull_amplitude=displacement;
    s->release_force=0;s->elapsed=0;s->pull_start=0;s->pull_velocity=0;s->motor_a=0;
    memcpy(s->tap,tap,sizeof(double)*s->m);
    for(int k=0;k<s->m;k++) {
        s->pull_start+=tap[k]*s->q[k];s->pull_velocity+=tap[k]*s->p[k];
        s->motor_a+=tap[k]*tap[k]*s->a[k];
    }
    for(int z=0;z<s->j;z++) {
        s->motor_u[z]=0;
        for(int k=0;k<s->m;k++)s->motor_u[z]+=s->phi[k*s->j+z]*s->a[k]*tap[k];
    }
    for(int z=0;z<s->j;z++)for(int l=0;l<s->j;l++)
        s->motor_G[z*s->j+l]=s->G[z*s->j+l]-s->weight*s->motor_u[z]*s->motor_u[l]/s->motor_a;
    for(int z=0;z<s->j;z++)for(int l=0;l<s->j;l++)s->motor_GT[l*s->j+z]=s->motor_G[z*s->j+l];
}
void bow_contact_state(void *ptr,double *q,double *p) {
    Contact *s=ptr;memcpy(q,s->q,sizeof(double)*s->m);memcpy(p,s->p,sizeof(double)*s->m);
}
void bow_contact_damp(void *ptr,double multiplier) {
    Contact *s=ptr;if(!(multiplier>0 && multiplier<1))return;
    s->started=1;
    for(int k=0;k<s->m;k++) {
        if(s->audit)s->dissipated+=.5*s->p[k]*s->p[k]*(1-multiplier*multiplier);
        s->p[k]*=multiplier;
    }
}
