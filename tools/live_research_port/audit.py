"""Check native causal observations against independent fitted magnitudes and convolution."""
import os
for k in ('OPENBLAS_NUM_THREADS','OMP_NUM_THREADS','VECLIB_MAXIMUM_THREADS'):os.environ[k]='1'
import ctypes as c, pathlib,json,time
import numpy as np
from scipy import signal, interpolate
R=pathlib.Path(__file__).resolve().parents[2]; A=R/'Packages/SarangiKit/Sources/SarangiKit/Resources'; O=R/'output/live-research-port'
a=json.loads((A/'sarangi_fit.json').read_text());lib=c.CDLL('/tmp/tarabdaar-live-fit.dylib');D=np.ctypeslib.ndpointer(dtype=np.float64,flags='C_CONTIGUOUS');F=np.ctypeslib.ndpointer(dtype=np.float32,flags='C_CONTIGUOUS')
lib.bow_fit_create.argtypes=[D,D,D,F,c.c_int,D,c.c_int,c.c_double];lib.bow_fit_create.restype=c.c_void_p
lib.bow_fit_set.argtypes=[c.c_void_p,c.c_int,c.c_double];lib.bow_fit_destroy.argtypes=[c.c_void_p];lib.bow_fit_curve.argtypes=[c.c_void_p,D,c.c_double,D];lib.bow_fit_impulse.argtypes=[c.c_void_p,D];lib.bow_fit_reset.argtypes=[c.c_void_p]
lib.bow_fit_process.argtypes=[c.c_void_p,D,D,c.c_void_p,c.c_int,D,D,D,D,D,c.c_int,c.c_int]
coef=np.array(a['coefficients']);body=np.array(a['bodyDB']);knots=np.array(a['bodyKnots']);modes=np.array(a['ringModes']);room=np.fromfile(A/'sarangi_fit_room.f32','<f4').reshape(3,-1)
def create():return lib.bow_fit_create(coef,body,knots,room,a['roomFrames'],modes,len(modes),a['forceGain'])
def render(p,wave,controls=(330,.03,.1,.15,1),chunk=128):
 y=wave.copy();side=np.zeros(len(y));peak=0
 for start in range(0,len(y),chunk):
  n=min(chunk,len(y)-start);cc=[np.full(2*n,float(v)) for v in controls];t=time.perf_counter_ns()
  lib.bow_fit_process(p,y[start:start+n],side[start:start+n],None,n,*cc,2*n,1);peak=max(peak,time.perf_counter_ns()-t)
 return y,peak/1e6
p=create();rng=np.random.default_rng(17);x=rng.normal(0,.01,14000);y,_=render(p,x);assert np.array_equal(x,y)
# Gain predictor independently uses scipy's spline basis and the exported matrix.
lib.bow_fit_set(p,0,1);lib.bow_fit_set(p,1,1);render(p,np.zeros(96000))
f=np.arange(2049)*48000/4096;B=interpolate.BSpline(np.r_[[-2]*4,np.arange(-1.5,2,.5),[2]*4],np.eye(11),3)
rows=[];gain_errors=[]
for hz,speed,force,pos in [(100,.02,.1,.1),(160,.07,.4,.22),(220,.1,.5,.12),(329,.03,.1,.15),(490,.07,.3,.2),(800,.01,.03,.06),(1200,.2,1,.24)]:
 raw=np.array([np.log2(hz/330),np.log2(speed/.03),np.log2(force/.1),(pos-.15)/.05]);db=np.zeros(2049)
 for i in range(500):lib.bow_fit_curve(p,raw,1,db)
 v=np.tanh(raw[1:]);X=np.r_[B(2*np.tanh(raw[0]/2)),v,v[0]*v[1],v[1]*v[2],v[2]*v[0],np.tanh(raw[0])*v,np.zeros(3)]
 g=12*np.tanh(X@coef/12);order=2*f/hz;j=np.clip(order.astype(int),0,127);w=.5-.5*np.cos(np.pi*np.clip(order-j,0,1))
 band=(.5-.5*np.cos(np.pi*np.clip((f-800)/400,0,1)))*(.5-.5*np.cos(np.pi*np.clip((10400-f)/800,0,1)))
 expected=((1-w)*g[j]+w*g[j+1])*band*(order<128)
 ix=np.clip(np.searchsorted(knots,f,side='right')-1,0,22);z=.5-.5*np.cos(np.pi*np.clip(np.log(np.maximum(f,1)/knots[ix])/np.log(knots[ix+1]/knots[ix]),0,1))
 expected+=((1-z)*body[ix]+z*body[ix+1])*(f>=120)*(f<=12000)
 gain_errors.append(float(abs(db-expected).max()));assert gain_errors[-1]<2e-7
 # bow_fit_impulse consumes the last internally generated curve; set it by rendering steady controls.
 render(p,np.zeros(144000),(hz,speed,force,pos,1));ir=np.zeros(2048);lib.bow_fit_impulse(p,ir)
 mag=20*np.log10(np.maximum(abs(np.fft.rfft(ir,4096)),1e-12));use=(f>=150)&(f<=10000)
 delta=mag[use]-expected[use];rows.append(dict(hz=hz,rms_db=float(np.sqrt(np.mean(delta**2))),p95_db=float(np.quantile(abs(delta),.95)),max_db=float(abs(delta).max())))
lib.bow_fit_destroy(p)
# Full 2-second room IR with exact early/late partition alignment and arbitrary host blocks.
p=create();lib.bow_fit_set(p,4,1);render(p,np.zeros(96000));x=np.zeros(100500);x[13]=.1
y,ms=render(p,x,chunk=127);expected=x.copy();expected[13:13+room.shape[1]]+=.1*room.astype(float).sum(0)
room_error=float(abs(y-expected).max());assert room_error<1e-9,room_error
lib.bow_fit_reset(p);fresh,_=render(p,np.zeros(48000));assert np.max(abs(fresh))==0
lib.bow_fit_destroy(p)
result=dict(gain_max_error_db=max(gain_errors),minimum_phase_response=rows,room_max_sample_error=room_error,room_peak_127_frame_ms=ms,byte_null=True,reset_silence=True)
(O/'native-audit.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
