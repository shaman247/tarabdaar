/* Preserve peaks near integer harmonics of the row tuning.
   This observes radiation only: it must never enter the mechanical return. */
#include "bow_tonal.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>
#if defined(__APPLE__) && !defined(BOW_TONAL_PORTABLE_FFT)
#include <Accelerate/Accelerate.h>
#define TONAL_ACCELERATE 1
#endif
#define MAX_N 16384
typedef struct {
    double *input,*output,*window,*re,*im;
    double *cosine,*sine,*power,*peak,*mask;
    unsigned short *reverse;
    unsigned int position;
    double cutoff,mix,selectivity,fundamental;
    int started,size,active,warmup;
#ifdef TONAL_ACCELERATE
    FFTSetupD transform;
    vDSP_Length log2size;
#endif
} Tonal;

void *bow_tonal_create(double fundamental_hz) {
    if(!isfinite(fundamental_hz) || fundamental_hz<70 || fundamental_hz>=48000)return NULL;
    // At least eight bins per harmonic spacing keeps half-harmonic peaks
    // resolvable on lower strings. Pack only this row's active transform;
    // cache-line padding avoids power-of-two strides aliasing every array.
    int n=2048,bits=11;
    while(n<MAX_N && fundamental_hz*n/96000.0<8) {n*=2;bits++;}
    const size_t stride=n+8;
    Tonal *s=calloc(1,sizeof(*s)+10*stride*sizeof(double)+n*sizeof(unsigned short));
    if(!s)return NULL;
    double *storage=(double *)(s+1);
    s->input=storage;s->output=storage+stride;s->window=storage+2*stride;
    s->re=storage+3*stride;s->im=storage+4*stride;
    s->cosine=storage+5*stride;s->sine=storage+6*stride;
    s->power=storage+7*stride;s->peak=storage+8*stride;s->mask=storage+9*stride;
    s->reverse=(unsigned short *)(storage+10*stride);
    s->fundamental=fundamental_hz;s->size=n;
#ifdef TONAL_ACCELERATE
    s->transform=vDSP_create_fftsetupD(bits,kFFTRadix2);
    if(!s->transform) {free(s);return NULL;}
    s->log2size=bits;
#endif
    for(int k=0;k<n;k++) {
        s->window[k]=.5-.5*cos(2*M_PI*k/n);
        unsigned int x=k,r=0;
        for(int b=0;b<bits;b++) {r=(r<<1)|(x&1);x>>=1;}
        s->reverse[k]=(unsigned short)r;
    }
    for(int k=0;k<n/2;k++) {
        s->cosine[k]=cos(2*M_PI*k/n);s->sine[k]=sin(2*M_PI*k/n);
    }
    return s;
}
void bow_tonal_destroy(void *state) {
    if(!state)return;
#ifdef TONAL_ACCELERATE
    vDSP_destroy_fftsetupD(((Tonal *)state)->transform);
#endif
    free(state);
}
int bow_tonal_latency(void *state) {return state?((Tonal *)state)->size:0;}

static void fft(Tonal *s,int inverse) {
#ifdef TONAL_ACCELERATE
    DSPDoubleSplitComplex data={s->re,s->im};
    vDSP_fft_zipD(s->transform,&data,1,s->log2size,inverse?kFFTDirection_Inverse:kFFTDirection_Forward);
#else
    const int n=s->size;
    for(int k=0;k<n;k++) {
        int j=s->reverse[k];
        if(j>k) {
            double r=s->re[k],i=s->im[k];
            s->re[k]=s->re[j];s->im[k]=s->im[j];s->re[j]=r;s->im[j]=i;
        }
    }
    for(int size=2;size<=n;size*=2) {
        int half=size/2,step=n/size;
        for(int start=0;start<n;start+=size)for(int j=0;j<half;j++) {
            int a=start+j,b=a+half,t=j*step;
            double wr=s->cosine[t],wi=inverse?s->sine[t]:-s->sine[t];
            double r=wr*s->re[b]-wi*s->im[b],i=wr*s->im[b]+wi*s->re[b];
            s->re[b]=s->re[a]-r;s->im[b]=s->im[a]-i;
            s->re[a]+=r;s->im[a]+=i;
        }
    }
#endif
}

static void frame(Tonal *s) {
    const int n=s->size,bins=n/2+1;
    // position points to the oldest input and the next unread output.
    for(int k=0;k<n;k++) {
        s->re[k]=s->input[(s->position+k)&(n-1)]*s->window[k];s->im[k]=0;
    }
    fft(s,0);
    for(int k=0;k<bins;k++) {
        double p=s->re[k]*s->re[k]+s->im[k]*s->im[k];
        s->power[k]+=.4*(p-s->power[k]);
    }
    const double threshold=4*pow(16,s->selectivity);
    // Absolute width is a fraction of harmonic spacing, not cents times
    // harmonic number: high bands must not widen until they touch.
    const double harmonicWidth=fmax(96000.0/n*.1,s->fundamental*(.12-.095*s->selectivity));
    const double residual=.063*pow(.1,s->selectivity);
    const double adjacent=1-.5*s->selectivity,shoulder=.5*(1-s->selectivity);
    memset(s->peak,0,sizeof(double)*bins);
    for(int k=1;k<bins-1;k++) {
        if(s->power[k]<s->power[k-1] || s->power[k]<s->power[k+1])continue;
        // Sub-bin peak location avoids making acceptance depend on the FFT
        // bin alignment. Only the nominal harmonic lattice can grant passage.
        double a=log(fmax(s->power[k-1],1e-30));
        double b=log(fmax(s->power[k],1e-30));
        double c=log(fmax(s->power[k+1],1e-30));
        double curvature=a-2*b+c;
        double offset=curvature < -1e-12 ? .5*(a-c)/curvature : 0;
        offset=fmin(.5,fmax(-.5,offset));
        double hz=(k+offset)*(96000.0/n);
        double harmonic=floor(hz/s->fundamental+.5);
        if(harmonic<1)continue;
        double distance=fabs(hz-harmonic*s->fundamental);
        if(distance>=harmonicWidth)continue;
        // Local median tolerates strong partials; power history suppresses
        // isolated random peaks. Bounded insertion sort, no heap or FFT plan.
        double neighbors[13];
        for(int j=0;j<13;j++) {
            int bin=k+j-6;bin=bin<0?0:(bin>=bins?bins-1:bin);
            double v=s->power[bin];int m=j;
            while(m>0 && neighbors[m-1]>v) {neighbors[m]=neighbors[m-1];m--;}
            neighbors[m]=v;
        }
        double contrast=s->power[k]/fmax(neighbors[6],1e-30);
        if(contrast<=threshold)continue;
        double edge=fmin(1,fmax(0,(distance/harmonicWidth-.5)*2));
        double harmonicKeep=1-edge*edge*(3-2*edge);
        s->peak[k]=harmonicKeep*fmin(1,(contrast-threshold)/threshold);
    }
    for(int k=0;k<bins;k++) {
        // Protect only accepted harmonic peaks and their window lobes.
        // Selectivity narrows the shoulders as well as harmonic eligibility.
        double keep=s->peak[k];
        if(k>0)keep=fmax(keep,adjacent*s->peak[k-1]);
        if(k+1<bins)keep=fmax(keep,adjacent*s->peak[k+1]);
        if(k>1)keep=fmax(keep,shoulder*s->peak[k-2]);
        if(k+2<bins)keep=fmax(keep,shoulder*s->peak[k+2]);
        double transition=fmin(1,fmax(0,(k*(96000.0/n)-s->cutoff+500)/1000));
        // A finite floor avoids hard spectral holes and brittle tails.
        s->mask[k]=1-transition*(1-(residual+(1-residual)*keep));
    }
    for(int k=0;k<n;k++) {
        double gain=s->mask[k<=n/2?k:n-k];
        s->re[k]*=gain;s->im[k]*=gain;
    }
    fft(s,1);
    // Four overlapping Hann analysis/synthesis windows sum to 3/2.
    for(int k=0;k<n;k++)
        s->output[(s->position+k)&(n-1)]+=s->re[k]*s->window[k]*(2.0/(3*n));
}

double bow_tonal_tick(void *state,double sample,double cutoff_hz,double selectivity) {
    Tonal *s=state;
    const int n=s->size,hop=n/4;
    const double slew=1-exp(-1/(96000.0*.04));
    selectivity=fmin(1,fmax(0,selectivity));
    double wet=cutoff_hz>=20000?0:1;
    if(!s->started) {
        s->cutoff=cutoff_hz;s->mix=wet;s->selectivity=selectivity;
        s->started=1;s->active=wet>0;
    }
    if(wet>0 && !s->active) {
        // Bypass keeps the delay ring live but does no spectral work. On
        // re-entry fill a complete overlap-add cycle before fading it in.
        memset(s->output,0,sizeof(double)*n);
        memset(s->power,0,sizeof(double)*(n/2+1));
        s->active=1;s->warmup=n;
    }
    s->selectivity+=slew*(selectivity-s->selectivity);
    s->cutoff+=slew*(cutoff_hz-s->cutoff);
    double target=s->warmup>0?0:wet;
    if(s->warmup>0)s->warmup--;
    s->mix+=slew*(target-s->mix);
    if(fabs(s->mix-target)<1e-9)s->mix=target;
    unsigned int p=s->position;
    double dry=s->input[p],filtered=s->output[p];
    s->input[p]=sample;s->output[p]=0;
    s->position=(p+1)&(n-1);
    if(s->active && (s->position&(hop-1))==0)frame(s);
    if(wet==0 && s->mix==0) {s->active=0;s->warmup=0;}
    // Both paths have the same latency: live bypass never combs against dry.
    if(s->mix==0)return dry;
    if(s->mix==1)return filtered;
    return dry+s->mix*(filtered-dry);
}
