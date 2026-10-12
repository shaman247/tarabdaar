#include "bow_fit.h"
#include "bow_radiation.h"
#include <Accelerate/Accelerate.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#define FFTN 4096
#define FIR 2048
#define HOP 480
#define RB 1024
#define RN 2048
#define MAXMODES 32

typedef struct {
    FFTSetupD fft;
    int partitions, cursor, position, work_band, work_part, working;
    double *hr, *hi, *xr, *xi;
    double input[RB], output[3][RB], pending[3][RB], overlap[3][RB], re[RN], im[RN];
    void *head[3];
} Room;
typedef struct {
    FFTSetupD fft;
    double coefficients[23*129], body[24], knots[24];
    double target[10], setting[10], memory[3], gains[129], activity;
    double re[FFTN], im[FFTN], curve[FFTN/2+1];
    double ir[FIR], oldIR[FIR], history[2][2*FIR];
    int pos, clock, engaged, room_engaged;
    Room room;
    int modes;
    double b0[MAXMODES], a1[MAXMODES], a2[MAXMODES], gain[MAXMODES];
    double x1, x2, y1[MAXMODES], y2[MAXMODES], force_gain;
    double fir[33], force_history[33];int force_pos;
    double shelf_b[3], shelf_a[2], shelf_x[2][2], shelf_y[2][2], shelf_db;
} Fit;
static void fft(FFTSetupD setup,double *r,double *i,int bits,int inverse) {
    DSPDoubleSplitComplex z={r,i};vDSP_fft_zipD(setup,&z,1,bits,inverse?FFT_INVERSE:FFT_FORWARD);
}
static double clamp(double x,double lo,double hi){return fmin(hi,fmax(lo,x));}
static double cosine(double u){return .5-.5*cos(M_PI*clamp(u,0,1));}
static int room_init(Room *r,const float *h,int count) {
    r->partitions=(count-2*RB+RB-1)/RB;if(r->partitions<1)r->partitions=1;
    r->fft=vDSP_create_fftsetupD(11,kFFTRadix2);
    size_t n=(size_t)r->partitions*RN;
    r->hr=calloc(3*n,sizeof(double));r->hi=calloc(3*n,sizeof(double));
    r->xr=calloc(n,sizeof(double));r->xi=calloc(n,sizeof(double));
    if(!r->fft||!r->hr||!r->hi||!r->xr||!r->xi)return 0;
    for(int band=0;band<3;band++) {
        double head[2*RB];for(int j=0;j<2*RB;j++)head[j]=j<count?h[band*count+j]:0;
        r->head[band]=bow_radiation_create(head,2*RB);if(!r->head[band])return 0;
        for(int p=0;p<r->partitions;p++) {
            memset(r->re,0,sizeof(r->re));memset(r->im,0,sizeof(r->im));
            for(int k=0;k<RB;k++){int j=2*RB+p*RB+k;if(j<count)r->re[k]=h[band*count+j];}
            fft(r->fft,r->re,r->im,11,0);
            memcpy(r->hr+(band*r->partitions+p)*RN,r->re,sizeof(r->re));
            memcpy(r->hi+(band*r->partitions+p)*RN,r->im,sizeof(r->im));
        }
    }
    return 1;
}
/* One extra early partition gives a full block to distribute the long-tail MACs. */
static void room_begin(Room *r) {
    memcpy(r->re,r->input,sizeof(r->input));memset(r->re+RB,0,RB*sizeof(double));memset(r->im,0,sizeof(r->im));
    fft(r->fft,r->re,r->im,11,0);
    memcpy(r->xr+r->cursor*RN,r->re,sizeof(r->re));memcpy(r->xi+r->cursor*RN,r->im,sizeof(r->im));
    memset(r->re,0,sizeof(r->re));memset(r->im,0,sizeof(r->im));
    r->work_band=r->work_part=0;r->working=1;
}
static void room_work(Room *r) {
    if(!r->working)return;
    int p=r->work_part,b=r->work_band,x=r->cursor-p;if(x<0)x+=r->partitions;
    double *hr=r->hr+(b*r->partitions+p)*RN,*hi=r->hi+(b*r->partitions+p)*RN;
    double *xr=r->xr+x*RN,*xi=r->xi+x*RN;
    for(int k=0;k<RN;k++){r->re[k]+=hr[k]*xr[k]-hi[k]*xi[k];r->im[k]+=hr[k]*xi[k]+hi[k]*xr[k];}
    if(++r->work_part==r->partitions) {
        fft(r->fft,r->re,r->im,11,1);
        for(int k=0;k<RB;k++){r->pending[b][k]=r->re[k]/RN+r->overlap[b][k];r->overlap[b][k]=r->re[k+RB]/RN;}
        memset(r->re,0,sizeof(r->re));memset(r->im,0,sizeof(r->im));
        r->work_part=0;if(++r->work_band==3)r->working=0;
    }
}
static double room_tick(Room *r,double input,const double *g) {
    int p=r->position;double y=0;
    for(int b=0;b<3;b++)y+=g[b]*(bow_radiation_tick(r->head[b],input)+r->output[b][p]);
    r->input[p]=input;
    // At most ceil(3*partitions/RB) partition products per sample; no callback-sized burst.
    int work=((p+1)*3*r->partitions)/RB-(p*3*r->partitions)/RB;
    while(work-->0)room_work(r);
    if(p==RB-1) {
        memcpy(r->output,r->pending,sizeof(r->output));
        r->cursor=(r->cursor+1)%r->partitions;room_begin(r);
    }
    r->position=(p+1)&(RB-1);return y;
}
static void features(const double *raw,double memory,const double *mean,double *x) {
    double u=2*tanh(raw[0]/2), knots[15]={-2,-2,-2,-2,-1.5,-1,-.5,0,.5,1,1.5,2,2,2,2};
    double b[14]={0};for(int i=0;i<14;i++)b[i]=(u>=knots[i]&&u<knots[i+1]);
    for(int d=1;d<=3;d++)for(int i=0;i<14-d;i++){
        double left=knots[i+d]-knots[i],right=knots[i+d+1]-knots[i+1];
        b[i]=(left?(u-knots[i])/left*b[i]:0)+(right?(knots[i+d+1]-u)/right*b[i+1]:0);
    }
    for(int i=0;i<11;i++)x[i]=b[i];
    double v[3];for(int i=0;i<3;i++){v[i]=tanh(raw[i+1]);x[11+i]=v[i];}
    x[14]=v[0]*v[1];x[15]=v[1]*v[2];x[16]=v[2]*v[0];
    for(int i=0;i<3;i++){x[17+i]=tanh(raw[0])*v[i];x[20+i]=memory*tanh(raw[i+1]-mean[i]);}
}
static void curve(Fit *s,const double *raw,double gate,double *db) {
    double a=exp(-.01/.18),x[23];for(int i=0;i<3;i++)s->memory[i]=a*s->memory[i]+(1-a)*raw[i+1];
    features(raw,s->setting[2],s->memory,x);
    a=exp(-.01/(fmax(10,s->setting[3])*.001));
    for(int h=0;h<129;h++) {
        double q=0;for(int j=0;j<23;j++)q+=x[j]*s->coefficients[j*129+h];
        s->gains[h]=a*s->gains[h]+(1-a)*12*tanh(q/12);
    }
    s->activity=a*s->activity+(1-a)*gate;
    double pitch=330*exp2(raw[0]);
    for(int k=0;k<=FFTN/2;k++) {
        double f=k*48000./FFTN,order=2*f/fmax(40,pitch),g=0;
        if(order<128){int j=(int)order;double w=cosine(order-j);g=(s->gains[j]*(1-w)+s->gains[j+1]*w)*cosine((f-800)/400)*cosine((10400-f)/800)*s->activity*s->setting[0];}
        if(f>=120&&f<=12000){int j=0;while(j<22&&f>s->knots[j+1])j++;double w=cosine(log(f/s->knots[j])/log(s->knots[j+1]/s->knots[j]));g+=s->setting[1]*((1-w)*s->body[j]+w*s->body[j+1]);}
        db[k]=clamp(g,-24,24);
    }
}
static void impulse(Fit *s) {
    for(int k=0;k<FFTN;k++){s->re[k]=s->curve[k<=FFTN/2?k:FFTN-k]*log(10)/20;s->im[k]=0;}
    fft(s->fft,s->re,s->im,12,1);
    for(int k=0;k<FFTN;k++){s->re[k]*=(k==0||k==FFTN/2?1:(k<FFTN/2?2:0))/(double)FFTN;s->im[k]=0;}
    fft(s->fft,s->re,s->im,12,0);
    for(int k=0;k<FFTN;k++){double a=exp(s->re[k]),p=s->im[k];s->re[k]=a*cos(p);s->im[k]=a*sin(p);}
    fft(s->fft,s->re,s->im,12,1);
    memcpy(s->oldIR,s->ir,sizeof(s->ir));
    for(int k=0;k<FIR;k++)s->ir[FIR-1-k]=s->re[k]/FFTN*(k<FIR-128?1:1-cosine((k-(FIR-128))/128.));
}
static void shelf(Fit *s,double db) {
    double A=pow(10,db/40),w=2*M_PI*6000/48000,c=cos(w),a=sin(w)/sqrt(2),t=2*sqrt(A)*a;
    double den=(A+1)-(A-1)*c+t;
    s->shelf_b[0]=A*((A+1)+(A-1)*c+t)/den;
    s->shelf_b[1]=-2*A*((A-1)+(A+1)*c)/den;s->shelf_b[2]=A*((A+1)+(A-1)*c-t)/den;
    s->shelf_a[0]=2*((A-1)-(A+1)*c)/den;s->shelf_a[1]=((A+1)-(A-1)*c-t)/den;s->shelf_db=db;
}
void *bow_fit_create(const double *coef,const double *body,const double *knots,const float *room,int count,const double *modes,int nm,double fg) {
    if(!coef||!body||!knots||!room||count<1||nm<0||nm>MAXMODES)return NULL;
    Fit *s=calloc(1,sizeof(*s));if(!s)return NULL;
    s->fft=vDSP_create_fftsetupD(12,kFFTRadix2);
    memcpy(s->coefficients,coef,sizeof(s->coefficients));memcpy(s->body,body,sizeof(s->body));memcpy(s->knots,knots,sizeof(s->knots));
    if(!s->fft||!room_init(&s->room,room,count)){bow_fit_destroy(s);return NULL;}
    s->modes=nm;s->force_gain=fg;
    for(int j=0;j<nm;j++){double sigma=log(1000)/modes[j*3+1],o=2*48000*tan(M_PI*modes[j*3]/48000),K=96000,den=K*K+2*sigma*K+o*o;
        s->b0[j]=2*sigma*K/den;s->a1[j]=2*(o*o-K*K)/den;s->a2[j]=(K*K-2*sigma*K+o*o)/den;s->gain[j]=modes[j*3+2];}
    double sum=0;for(int k=0;k<33;k++){double t=k-16;s->fir[k]=(t==0?.45:sin(M_PI*.45*t)/(M_PI*t))*(.54-.46*cos(2*M_PI*k/32));sum+=s->fir[k];}
    for(int k=0;k<33;k++)s->fir[k]/=sum;
    s->target[2]=s->setting[2]=1;s->target[3]=s->setting[3]=30;
    s->ir[FIR-1]=s->oldIR[FIR-1]=1;shelf(s,0);return s;
}
void bow_fit_set(void *v,int k,double value){if(!v||k<0||k>=10||!isfinite(value))return;Fit*s=v;
    double lo=0,hi=2;if(k==3){lo=10;hi=150;}if((k>=5&&k<=7)||k==9){lo=-12;hi=12;}
    s->target[k]=clamp(value,lo,hi);
}
void bow_fit_curve(void*v,const double*raw,double gate,double*db){curve(v,raw,gate,db);}
void bow_fit_impulse(void*v,double*h){Fit*s=v;impulse(s);for(int k=0;k<FIR;k++)h[k]=s->ir[FIR-1-k];}
void bow_fit_process(void *v,double *mid,double *side,const double *force,int n,const double *hz,const double *speed,const double *load,const double *position,const double *gate,int stride,int slots) {
    Fit*s=v;if(!s)return;
    int active=s->target[0]!=0||s->target[1]!=0||s->target[4]!=0||s->target[8]!=0||s->target[9]!=0;
    if(!s->engaged&&!active)return;s->engaged=1;
    for(int i=0;i<n;i++) {
        for(int k=0;k<10;k++){s->setting[k]+=(1-exp(-1./1440))*(s->target[k]-s->setting[k]);if(fabs(s->setting[k]-s->target[k])<1e-10)s->setting[k]=s->target[k];}
        if(s->clock==0) {
            double raw[4]={0},total=1e-40,ss=0,g=0,maxeff=0;
            for(int j=0;j<slots;j++){int k=j*stride+2*i;double e=fmax(0,speed[k]*load[k]*gate[k]);if(e>maxeff)maxeff=e;}
            for(int j=0;j<slots;j++) {int k=j*stride+2*i;double w=pow(fmax(0,speed[k]*load[k]*gate[k])/fmax(maxeff,1e-20),8);
                total+=w;ss+=w*w;g+=w*gate[k];raw[0]+=w*log2(fmax(hz[k],40)/330);raw[1]+=w*log2(fmax(speed[k],.001)/.03);raw[2]+=w*log2(fmax(load[k],.002)/.1);raw[3]+=w*(position[k]-.15)/.05;}
            for(int j=0;j<4;j++)raw[j]/=total;g=g/total*cosine((ss/(total*total)-.5)/.35);
            curve(s,raw,g,s->curve);impulse(s);shelf(s,s->setting[9]);
        }
        double ring=0;
        if(force) {
            double filtered=0;
            for(int sub=0;sub<2;sub++){s->force_history[s->force_pos]=force[2*i+sub];if(sub==0)for(int k=0;k<33;k++)filtered+=s->fir[k]*s->force_history[(s->force_pos-k+33)%33];s->force_pos=(s->force_pos+1)%33;}
            double x=filtered*s->force_gain;
            for(int k=0;k<s->modes;k++){double y=s->b0[k]*(x-s->x2)-s->a1[k]*s->y1[k]-s->a2[k]*s->y2[k];s->y2[k]=s->y1[k];s->y1[k]=y;ring+=s->gain[k]*y;}s->x2=s->x1;s->x1=x;
        }
        double value[2]={mid[i]+s->setting[8]*ring,side?side[i]:0};
        for(int c=0;c<(side?2:1);c++) {
            double x=value[c],y=s->shelf_b[0]*x+s->shelf_b[1]*s->shelf_x[c][0]+s->shelf_b[2]*s->shelf_x[c][1]-s->shelf_a[0]*s->shelf_y[c][0]-s->shelf_a[1]*s->shelf_y[c][1];
            s->shelf_x[c][1]=s->shelf_x[c][0];s->shelf_x[c][0]=x;s->shelf_y[c][1]=s->shelf_y[c][0];s->shelf_y[c][0]=y;
            if(s->setting[9]==0)y=x;
            s->history[c][s->pos]=s->history[c][s->pos+FIR]=y;
            if(s->setting[0]!=0||s->setting[1]!=0||s->target[0]!=0||s->target[1]!=0) {
                double a,b;vDSP_dotprD(s->history[c]+s->pos+1,1,s->oldIR,1,&a,FIR);vDSP_dotprD(s->history[c]+s->pos+1,1,s->ir,1,&b,FIR);
                value[c]=a+(b-a)*(s->clock/(double)HOP);
            } else value[c]=y;
        }
        s->pos=(s->pos+1)%FIR;
        if(s->target[4]!=0)s->room_engaged=1;
        if(s->room_engaged){double gains[3];for(int b=0;b<3;b++)gains[b]=pow(10,s->setting[5+b]/20);value[0]+=s->setting[4]*room_tick(&s->room,value[0],gains);}
        mid[i]=value[0];if(side)side[i]=value[1];s->clock=(s->clock+1)%HOP;
    }
}
void bow_fit_reset(void *v) {
    Fit*s=v;if(!s)return;
    memset(s->memory,0,sizeof(s->memory));memset(s->gains,0,sizeof(s->gains));s->activity=0;
    memset(s->history,0,sizeof(s->history));memset(s->ir,0,sizeof(s->ir));memset(s->oldIR,0,sizeof(s->oldIR));s->ir[FIR-1]=s->oldIR[FIR-1]=1;
    memset(s->y1,0,sizeof(s->y1));memset(s->y2,0,sizeof(s->y2));s->x1=s->x2=0;memset(s->force_history,0,sizeof(s->force_history));s->force_pos=0;
    memset(s->shelf_x,0,sizeof(s->shelf_x));memset(s->shelf_y,0,sizeof(s->shelf_y));s->pos=s->clock=0;
    Room*r=&s->room;memset(r->xr,0,r->partitions*RN*sizeof(double));memset(r->xi,0,r->partitions*RN*sizeof(double));memset(r->input,0,sizeof(r->input));memset(r->output,0,sizeof(r->output));memset(r->pending,0,sizeof(r->pending));r->working=0;memset(r->overlap,0,sizeof(r->overlap));r->cursor=r->position=0;
    for(int b=0;b<3;b++)bow_radiation_reset(r->head[b]);
}
void bow_fit_destroy(void*v){Fit*s=v;if(!s)return;if(s->fft)vDSP_destroy_fftsetupD(s->fft);Room*r=&s->room;if(r->fft)vDSP_destroy_fftsetupD(r->fft);for(int b=0;b<3;b++)bow_radiation_destroy(r->head[b]);free(r->hr);free(r->hi);free(r->xr);free(r->xi);free(s);}
