"""Export only shared model coefficients and synthetic room responses for the live voice."""
import os
for k in ('OPENBLAS_NUM_THREADS','OMP_NUM_THREADS','VECLIB_MAXIMUM_THREADS'):os.environ[k]='1'
import json, pathlib, hashlib, sys, subprocess
import numpy as np
from scipy import signal
ROOT=pathlib.Path(__file__).resolve().parents[2]; B=ROOT/'output/reference_onsets/neighborhood-model'
OUT=ROOT/'Packages/SarangiKit/Sources/SarangiKit/Resources'
read=lambda p:json.loads(p.read_text())
model=read(B/'short-time-timbre/shared-response/models/both12.json')
co=read(B/'factorized-empirical-timbre/native/gesture-1-1/13/coefficients.json')
job=read(B/'factorized-empirical-timbre/native/gesture-1-1/13/job.json')
# Render no notes solely to export the unfitted formula residues of the frozen renderer.
work=ROOT/'output/live-research-port';work.mkdir(exist_ok=True)
job.pop('bodyRadiation');job.pop('sourceTrace');job['seconds']=.1;job['points']=job['points'][:2];job['events']=[]
job['output']=str(work/'formula.raw');job['bodyRadiationDiagnostics']=str(work/'formula.json')
binary=read(B/'perceptual-source-curvature/ready.json')['binary']
proc=subprocess.run([binary],input=json.dumps(job)+'\n',text=True,capture_output=True)
if proc.returncode: raise RuntimeError(proc.stderr[-4000:]+proc.stdout[-1000:])
base=read(work/'formula.json');assert co['a1']==base['a1'] and co['a2']==base['a2']
ratio=np.array(co['bC'])/np.array(base['bC']);assert np.isfinite(ratio).all()
# Exact accepted synthetic image-room IR, complementary observation bands, fitted shared gains.
h=np.load(B/'tail-transfer/ir/room-1.6.npy');lo=signal.firwin(257,1000,fs=48000);top=signal.firwin(257,3000,fs=48000)
delta=np.zeros(257);delta[128]=1
weights=np.array(read(B/'tail-transfer/model.json')['gains'])[[0,4,5,6]]
weights[1:] *= 1+np.array(read(B/'joint-bow-acoustic/localized/paired/selection.json')['selected']['reverb'])
room=np.array([signal.fftconvolve(h,band)*w/weights[0] for band,w in zip([lo,top-lo,delta-top],weights[1:])])
room.astype('<f4').tofile(OUT/'sarangi_fit_room.f32')
modes=read(B/'tail-transfer-gap/quiet-decay/fullness-followups/response.json')['modes']
result=dict(version=1, sampleRate=48000, coefficients=model['coefficients'], bodyDB=model['body_db'], bodyKnots=model['body_knots'],
 radiationDelta=(np.array(co['bC'])-np.array(base['bC'])).tolist(), radiationMain=job['overrides']['bow_body_rad'], radiationTail=job['overrides']['bow_body_tail_rad'], roomFrames=room.shape[1], roomDryGain=float(weights[0]),
 ringModes=[[m['hz'],m['t60'],m['gain']] for m in modes],
 forceGain=100/(.5*.2332*13.521034559320478),
 sourceSHA256=hashlib.sha256((B/'short-time-timbre/shared-response/models/both12.json').read_bytes()).hexdigest())
(OUT/'sarangi_fit.json').write_text(json.dumps(result,separators=(',',':'))+'\n')
print('exported',room.shape,'radiation ratios',ratio.min(),ratio.max(),'ring modes',len(modes))
