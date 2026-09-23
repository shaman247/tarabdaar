/* Optional corrected SAV contact solver. Exact modal propagation and a
   closed-form positive contact update, followed by passive energy correction.
   Aggregate damping differs from Newton's local Hunt-Crossley loss.
   Derivation and listening evidence: docs/history/Codex-2026-09-20-taraf-sav-decay.md. */
static double physical_potential(Contact *s) {
    double value=0;
    for(int z=0;z<s->j;z++) {
        double y=s->bone[z];
        for(int k=0;k<s->m;k++)y-=s->phi[k*s->j+z]*s->q[k];
        if(y>0)value+=s->kc*pow(y,s->alpha+1)/(s->alpha+1);
    }
    return value;
}

/* Smallest positive root of A*x*x+B*x+P=0, P>0. */
static double positive_root(double A,double B,double P) {
    double disc=B*B-4*A*P;
    if(disc<0 || (A>=0 && B>=0))return INFINITY;
    if(A<0 && B>0)return (sqrt(disc)+B)/(-2*A);
    double denominator=sqrt(fmax(0,disc))-B;
    return denominator>0 ? 2*P/denominator : INFINITY;
}

static int sav_step(Contact *s,const double *old,const double *star,
                    double *eta,double *f) {
    const int j=s->j;
    double g[JJ]={0},nominal[JJ]={0},potential=0,endpoint[JJ],delta[JJ],Gg[JJ]={0};
    // Last force predicts the midpoint; it is never iteratively corrected.
    memcpy(endpoint,star,sizeof(double)*j);
    const double *GT=s->pulling?s->motor_GT:s->GT;
    for(int l=0;l<j;l++)if(s->last[l]!=0)
        for(int z=0;z<j;z++)endpoint[z]-=GT[l*j+z]*s->last[l];
    for(int z=0;z<j;z++) {
        double y=fmax(0,.5*(old[z]+endpoint[z]));
        if(y>0) {nominal[z]=s->kc*pow(y,s->alpha);potential+=nominal[z]*y/(s->alpha+1);}
        delta[z]=star[z]-old[z];
    }
    double theory=sqrt(2*potential),sumg=0;
    int leaving=theory==0;
    for(int z=0;z<j;z++) {
        nominal[z]=theory>0?nominal[z]/theory:0;
        g[z]=leaving?s->sav_previous[z]:nominal[z];sumg+=g[z];
    }
    double h=0,b=0;
    for(int l=0;l<j;l++)if(g[l]!=0)
        for(int z=0;z<j;z++)Gg[z]+=GT[l*j+z]*g[l];
    for(int z=0;z<j;z++) {b+=g[z]*delta[z];h+=g[z]*Gg[z];}
    h=fmax(0,h);
    const double P=s->sav_psi;
    // Aggregate loss is a rank-one approximation to distributed Hunt-Crossley
    // damping. Its work is nonnegative. It is not the original local loss law.
    const double c=(!leaving && sumg>0)?s->hc*P/sumg:0;
    const double t=.5+c/s->dt;
    double scale=1;
    if(leaving) {
        scale=P>0 && sumg>0?positive_root(-.5*P*h,b,P):0;
        if(!isfinite(scale)){return 0;}
    } else if(P==0) {
        if(b<0)scale=0;
    } else {
        // Both the next auxiliary variable and the emitted force stay positive.
        if(P+(t-1)*P*h+b<0)
            scale=fmin(scale,positive_root((t-1)*P*h,b,P));
        if(b<0)scale=fmin(scale,P/(-t*b));
    }
    double lambda=(P+t*scale*b)/(1+t*scale*scale*h);
    if(!isfinite(lambda) || lambda < -1e-12*fmax(1,P)){return 0;}
    lambda=fmax(0,lambda);
    for(int z=0;z<j;z++)f[z]=scale*g[z]*lambda;
    double change=scale*(b-scale*h*P)/(1+t*scale*scale*h);
    for(int z=0;z<j;z++) {
        eta[z]=star[z]-scale*lambda*Gg[z];
    }
    double next=P+change;
    if(!isfinite(next) || next < -1e-10*fmax(1,P)){return 0;}
    s->sav_psi=leaving && sumg>0?0:fmax(0,next);
    if(leaving && sumg==0 && P>1e-12){return 0;}
    if(s->audit)s->dissipated+=s->weight*c/s->dt*change*change;
    for(int z=0;z<j;z++) {
        s->sav_previous[z]=nominal[z];s->last[z]=f[z];
    }
    /* Passive consistency correction for the optional SAV solver.
       Remove excess auxiliary energy after the contact update. This adds numerical
       dissipation; it is not an energy-conserving projection or the original local
       contact damping law. It leaves this step's force and modal state untouched. */
    double physical=0;
    for(int z=0;z<j;z++)if(eta[z]>0)
        physical+=s->kc*pow(eta[z],s->alpha+1)/(s->alpha+1);
    double corrected=fmin(s->sav_psi,sqrt(2*physical));
    if(s->audit && corrected<s->sav_psi) {
        double removed=s->weight*.5*(s->sav_psi-corrected)*(s->sav_psi+corrected);
        s->dissipated+=removed;
    }
    s->sav_psi=corrected;
    return 1;
}

static void sav_initialize(Contact *s) {
    s->sav_psi=sqrt(2*physical_potential(s));
    for(int z=0;z<s->j;z++) {
        double y=s->bone[z];for(int k=0;k<s->m;k++)y-=s->phi[k*s->j+z]*s->q[k];
        s->last[z]=y>0?s->kc*pow(y,s->alpha):0;
        s->sav_previous[z]=s->sav_psi>0?s->last[z]/s->sav_psi:0;
    }
}
