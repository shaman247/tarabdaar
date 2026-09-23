/* Build-time stationary state of the existing split row update. No change to
   the runtime contact solver. Called before any render jobs are dispatched. */
#include "bow_poly_internal.h"

static int init_linear(int n, double *a, double *b) {
    for (int k=0;k<n;k++) {
        int pivot=k;
        for (int i=k+1;i<n;i++) if(fabs(a[i*n+k])>fabs(a[pivot*n+k])) pivot=i;
        if(!isfinite(a[pivot*n+k]) || fabs(a[pivot*n+k])<1e-30) return 0;
        if(pivot!=k) {
            for(int j=k;j<n;j++) {double v=a[k*n+j];a[k*n+j]=a[pivot*n+j];a[pivot*n+j]=v;}
            double v=b[k];b[k]=b[pivot];b[pivot]=v;
        }
        for(int i=k+1;i<n;i++) {
            double c=a[i*n+k]/a[k*n+k];
            for(int j=k;j<n;j++) a[i*n+j]-=c*a[k*n+j];
            b[i]-=c*b[k];
        }
    }
    for(int i=n-1;i>=0;i--) {
        for(int j=i+1;j<n;j++) b[i]-=a[i*n+j]*b[j];
        b[i]/=a[i*n+i];
        if(!isfinite(b[i])) return 0;
    }
    return 1;
}

typedef struct {
    int j;
    double kc, alpha, hcb, es, fs;
    double U[JT_MAXJ*JT_MAXJ], V[JT_MAXJ*JT_MAXJ];
    const float *G, *b;
} init_equation;

static double init_residual(const init_equation *c, const double *x,
                            double *r, double *jac) {
    const int j=c->j, n=2*j;
    double f[JT_MAXJ], df[JT_MAXJ], h[JT_MAXJ];
    for(int i=0;i<j;i++) {
        double e=fmax(c->es*x[i],0);
        f[i]=c->kc*pow(e,c->alpha);
        df[i]=c->kc*c->alpha*pow(e,c->alpha-1);
        h[i]=c->fs*x[j+i];
    }
    double norm=0;
    if(jac) memset(jac,0,n*n*sizeof(double));
    for(int i=0;i<j;i++) {
        double u=0,v=0,g=0;
        for(int k=0;k<j;k++) {
            u+=c->U[i*j+k]*h[k];v+=c->V[i*j+k]*h[k];g+=c->G[i*j+k]*f[k];
        }
        const double raw=1-c->hcb*v;
        const double hc=fmin(1,fmax(.15,raw));
        r[i]=(c->es*x[i]+u+g-c->b[i])/c->es;
        r[j+i]=(h[i]-hc*f[i])/c->fs;
        norm+=r[i]*r[i]+r[j+i]*r[j+i];
        if(jac) for(int k=0;k<j;k++) {
            jac[i*n+k]=(i==k)+c->G[i*j+k]*df[k];
            jac[i*n+j+k]=c->U[i*j+k]*c->fs/c->es;
            jac[(j+i)*n+k]=i==k ? -hc*df[i]*c->es/c->fs : 0;
            jac[(j+i)*n+j+k]=(i==k)
                + ((raw>.15 && raw<1) ? f[i]*c->hcb*c->V[i*j+k] : 0);
        }
    }
    return norm;
}

static int init_row(bow_poly_state_t *st,int s,double *q,double *p) {
    const int m=st->jtM[s],j=st->jtJ,n=2*j,mo=st->jtMOff[s],zo=st->jtZOff[s];
    const double dt=(double)st->jtDiv/st->sr;
    init_equation c={0}; c.j=j;
    // The running contact step rounds these to float as well.
    c.kc=(float)st->jtKc;
    c.alpha=(float)(st->jtRowContactOn?st->jtRowAlpha[s]:st->jtAlpha);
    c.hcb=(float)(st->jtRowContactOn?st->jtRowHcB[s]:st->jtHcB);
    c.b=st->jtB+s*j;c.G=st->jtG+s*j*j;
    c.es=1e-12;c.fs=1e-12;
    const float *phi=st->jtPhiU+zo,*force=st->jtPhiF+zo;
    double Q[JT_MAXM*JT_MAXJ],P[JT_MAXM*JT_MAXJ];
    double x[2*JT_MAXJ],r[2*JT_MAXJ],jac[4*JT_MAXJ*JT_MAXJ];
    for(int i=0;i<j;i++) c.es=fmax(c.es,fabs(c.b[i]));
    for(int k=0;k<m;k++) {
        const double a=st->jtCa[mo+k],b=st->jtCb[mo+k],w=st->jtWd[mo+k];
        const double det=(1-a)*(1-a)+b*b;
        if(det<1e-30 || w<=0) return 0;
        const double qf=((1-a)*.5*dt*dt+b/w*dt)/det;
        const double pf=(-b*w*.5*dt*dt+(1-a)*dt)/det;
        for(int i=0;i<j;i++) {
            Q[k*j+i]=qf*force[k*j+i];P[k*j+i]=pf*force[k*j+i];
        }
        for(int i=0;i<j;i++) for(int z=0;z<j;z++) {
            c.U[i*j+z]+=phi[k*j+i]*(a*Q[k*j+z]+b/w*P[k*j+z]);
            c.V[i*j+z]+=phi[k*j+i]*(-b*w*Q[k*j+z]+a*P[k*j+z]);
        }
    }
    for(int i=0;i<j;i++) {
        double u=0;
        for(int k=0;k<m;k++) u+=phi[k*j+i]*st->jtQ[mo+k];
        x[i]=(c.b[i]-u)/c.es;
        x[j+i]=c.kc*pow(fmax(c.b[i]-u,0),c.alpha);
        c.fs=fmax(c.fs,x[j+i]);
    }
    for(int i=0;i<j;i++) x[j+i]/=c.fs;
    for(int it=0;it<80;it++) {
        double norm=init_residual(&c,x,r,jac),largest=0;
        for(int i=0;i<n;i++) largest=fmax(largest,fabs(r[i]));
        if(!isfinite(norm)) return 0;
        if(largest<1e-9) {
            for(int k=0;k<m;k++) {
                q[k]=p[k]=0;
                for(int i=0;i<j;i++) {q[k]+=Q[k*j+i]*x[j+i]*c.fs;p[k]+=P[k*j+i]*x[j+i]*c.fs;}
                if(!isfinite(q[k]) || !isfinite(p[k])) return 0;
            }
            // This fixed point describes the full step, not the deep-contact
            // quarter-step branch. Reject any state that would select it.
            const double deep=st->jtRowContactOn?st->jtRowDeep[s]:st->jtDeep;
            for(int i=0;i<j;i++) {
                double u=0;
                for(int z=0;z<j;z++) u+=c.U[i*j+z]*x[j+z]*c.fs;
                if(c.b[i]-u>deep || x[j+i]<-1e-10) return 0;
            }
            return 1;
        }
        for(int i=0;i<n;i++) r[i]=-r[i];
        if(!init_linear(n,jac,r)) return 0;
        double fraction=1,next[2*JT_MAXJ],rr[2*JT_MAXJ];int accepted=0;
        for(int ls=0;ls<30;ls++,fraction*=.5) {
            for(int i=0;i<n;i++) next[i]=x[i]+fraction*r[i];
            if(init_residual(&c,next,rr,NULL)<norm) {memcpy(x,next,n*sizeof(double));accepted=1;break;}
        }
        if(!accepted) return 0;
    }
    return 0;
}

int bow_poly_jt_prepare_initial_state(void *vst) {
    bow_poly_state_t *st=vst;
    if(!st || st->njt==0) return 1;
    // Moving bones retain the normal slewed settle path. Never reset an
    // already rendered row or race a dispatcher with this build-only API.
    if(st->jtEvTgt!=0 || st->jtLift!=0 || st->jtDampMul!=0) return 0;
    int count=0;
    for(int s=0;s<st->njt;s++) {
        if(st->jtEvOfsTgt[s]!=0 || st->jtM[s]>JT_MAXM) return 0;
        count+=st->jtM[s];
    }
    if(st->jtJ<1 || st->jtJ>JT_MAXJ) return 0;
    double *q=calloc(count,sizeof(double)),*p=calloc(count,sizeof(double));
    if(!q || !p) {free(q);free(p);return 0;}
    int ok=1;
    for(int s=0;s<st->njt && ok;s++) ok=init_row(st,s,q+st->jtMOff[s],p+st->jtMOff[s]);
    if(ok) {memcpy(st->jtQ,q,count*sizeof(double));memcpy(st->jtP,p,count*sizeof(double));}
    free(q);free(p);return ok;
}
