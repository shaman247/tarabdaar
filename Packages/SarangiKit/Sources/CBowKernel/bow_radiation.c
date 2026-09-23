/* A direct head pays for one block of lookahead on the partitioned FIR tail.
   The complete fitted impulse response is retained, including its phase. */
#include "bow_radiation.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>
#if defined(__APPLE__) && !defined(BOW_RADIATION_PORTABLE_FFT)
#include <Accelerate/Accelerate.h>
#define RADIATION_ACCELERATE 1
#endif

#define BLOCK 64
#define N (2*BLOCK)
#define BITS 7
#define MAX_TAPS 2049
#define PARTS ((MAX_TAPS-1)/BLOCK)

typedef struct {
    int head_count, partitions, position, cursor;
    double head[BLOCK], history[2*BLOCK], input[BLOCK];
    double output[BLOCK], overlap[BLOCK];
    double hr[PARTS][N], hi[PARTS][N], xr[PARTS][N], xi[PARTS][N];
    double re[N], im[N];
    unsigned char active[PARTS];
#ifdef RADIATION_ACCELERATE
    FFTSetupD fft;
#else
    double cosine[N/2], sine[N/2];
#endif
} Radiation;

static void transform(Radiation *s, int inverse) {
#ifdef RADIATION_ACCELERATE
    DSPDoubleSplitComplex data={s->re,s->im};
    vDSP_fft_zipD(s->fft,&data,1,BITS,inverse?kFFTDirection_Inverse:kFFTDirection_Forward);
#else
    for(int k=0;k<N;k++) {
        unsigned int x=k,r=0;
        for(int b=0;b<BITS;b++) {r=(r<<1)|(x&1);x>>=1;}
        if(r>(unsigned int)k) {
            double re=s->re[k],im=s->im[k];
            s->re[k]=s->re[r];s->im[k]=s->im[r];s->re[r]=re;s->im[r]=im;
        }
    }
    for(int size=2;size<=N;size*=2) {
        int half=size/2,step=N/size;
        for(int start=0;start<N;start+=size)for(int j=0;j<half;j++) {
            int a=start+j,b=a+half,t=j*step;
            double wr=s->cosine[t],wi=inverse?s->sine[t]:-s->sine[t];
            double re=wr*s->re[b]-wi*s->im[b],im=wr*s->im[b]+wi*s->re[b];
            s->re[b]=s->re[a]-re;s->im[b]=s->im[a]-im;
            s->re[a]+=re;s->im[a]+=im;
        }
    }
#endif
}

void *bow_radiation_create(const double *coefficients,int count) {
    if(!coefficients || count<1 || count>MAX_TAPS)return NULL;
    Radiation *s=calloc(1,sizeof(*s));if(!s)return NULL;
    s->head_count=count<BLOCK?count:BLOCK;
    s->partitions=(count-s->head_count+BLOCK-1)/BLOCK;
    memcpy(s->head,coefficients,sizeof(double)*s->head_count);
#ifdef RADIATION_ACCELERATE
    s->fft=vDSP_create_fftsetupD(BITS,kFFTRadix2);
    if(!s->fft) {free(s);return NULL;}
#else
    for(int k=0;k<N/2;k++) {
        s->cosine[k]=cos(2*M_PI*k/N);s->sine[k]=sin(2*M_PI*k/N);
    }
#endif
    for(int p=0;p<s->partitions;p++) {
        memset(s->re,0,sizeof(s->re));memset(s->im,0,sizeof(s->im));
        for(int k=0;k<BLOCK && (p+1)*BLOCK+k<count;k++)s->re[k]=coefficients[(p+1)*BLOCK+k];
        transform(s,0);
        memcpy(s->hr[p],s->re,sizeof(s->re));memcpy(s->hi[p],s->im,sizeof(s->im));
    }
    return s;
}

static void tail(Radiation *s) {
    const int cursor=s->cursor;
    int active=0;
    for(int k=0;k<BLOCK;k++)if(s->input[k]!=0)active=1;
    s->active[cursor]=active;
    if(active) {
        memcpy(s->re,s->input,sizeof(s->input));
        memset(s->re+BLOCK,0,BLOCK*sizeof(double));memset(s->im,0,sizeof(s->im));
        transform(s,0);
        memcpy(s->xr[cursor],s->re,sizeof(s->re));memcpy(s->xi[cursor],s->im,sizeof(s->im));
    }
    memset(s->re,0,sizeof(s->re));memset(s->im,0,sizeof(s->im));
    int any=0;
    for(int p=0;p<s->partitions;p++) {
        int x=cursor-p;if(x<0)x+=s->partitions;
        if(!s->active[x])continue;
        any=1;
        for(int k=0;k<N;k++) {
            s->re[k]+=s->hr[p][k]*s->xr[x][k]-s->hi[p][k]*s->xi[x][k];
            s->im[k]+=s->hr[p][k]*s->xi[x][k]+s->hi[p][k]*s->xr[x][k];
        }
    }
    if(any)transform(s,1);
    for(int k=0;k<BLOCK;k++) {
        s->output[k]=s->re[k]/N+s->overlap[k];
        s->overlap[k]=s->re[k+BLOCK]/N;
    }
    s->cursor=(cursor+1)%s->partitions;
}

double bow_radiation_tick(void *state,double input) {
    Radiation *s=state;
    int pos=s->position;
    s->history[pos]=s->history[pos+BLOCK]=input;
    const double *history=s->history+BLOCK+pos;
    double a=0,b=0,c=0,d=0;
    int k=0;
    for(;k+3<s->head_count;k+=4) {
        a+=s->head[k]*history[-k];b+=s->head[k+1]*history[-k-1];
        c+=s->head[k+2]*history[-k-2];d+=s->head[k+3]*history[-k-3];
    }
    double y=(a+b)+(c+d);
    for(;k<s->head_count;k++)y+=s->head[k]*history[-k];
    if(s->partitions) {
        y+=s->output[pos];s->input[pos]=input;
        // This completed input block first contributes at the NEXT sample:
        // the FIR tail starts at tap BLOCK, so no extra output delay is needed.
        if(pos==BLOCK-1)tail(s);
    }
    s->position=(pos+1)&(BLOCK-1);
    return y;
}

void bow_radiation_destroy(void *state) {
    Radiation *s=state;if(!s)return;
#ifdef RADIATION_ACCELERATE
    vDSP_destroy_fftsetupD(s->fft);
#endif
    free(s);
}
