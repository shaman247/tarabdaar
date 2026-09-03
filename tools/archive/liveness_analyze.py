#!/usr/bin/env python3
"""Analysis of bowed-string samples: envelope, sustain modulation, legato transitions."""
import numpy as np, sys, warnings
from scipy.io import wavfile
from scipy.signal import stft, get_window
warnings.filterwarnings("ignore")

def load(path):
    sr, x = wavfile.read(path)
    x = x.astype(np.float64)
    if x.ndim == 2: x = x.mean(axis=1)
    return sr, x

def rms_env(x, sr, win_ms=10.0):
    n = int(sr * win_ms / 1000)
    nwin = len(x) // n
    e = np.sqrt(np.mean(x[:nwin*n].reshape(nwin, n)**2, axis=1))
    t = (np.arange(nwin) + 0.5) * n / sr
    return t, e

def db(x): return 20*np.log10(np.maximum(x, 1e-12))

def pitch_track(x, sr, f0_guess, t0, t1, hop_ms=10):
    """Track f0 via phase of a narrowband DFT around f0_guess harmonics."""
    hop = int(sr*hop_ms/1000); win = int(sr*0.04)
    w = get_window("hann", win)
    ts, f0s = [], []
    period = sr / f0_guess
    for start in range(int(t0*sr), int(t1*sr)-win, hop):
        seg = x[start:start+win]*w
        # autocorrelation refine
        spec = np.fft.rfft(seg, n=2*win)
        ac = np.fft.irfft(np.abs(spec)**2)
        lo, hi = int(period*0.9), int(period*1.1)
        if hi >= len(ac): break
        k = lo + np.argmax(ac[lo:hi])
        # parabolic interp
        if 0 < k < len(ac)-1:
            a, b, c = ac[k-1], ac[k], ac[k+1]
            d = 0.5*(a-c)/(a-2*b+c) if (a-2*b+c) != 0 else 0
            k = k + d
        ts.append(start/sr); f0s.append(sr/k)
    return np.array(ts), np.array(f0s)

def harmonic_tracks(x, sr, f0, nharm, t0, t1, hop_ms=10):
    """Amplitude of each harmonic over time via heterodyne."""
    hop = int(sr*hop_ms/1000); win = int(sr*0.04)
    w = get_window("hann", win); wsum = w.sum()
    n = np.arange(win)
    ts, amps = [], []
    for start in range(int(t0*sr), int(t1*sr)-win, hop):
        seg = x[start:start+win]*w
        row = []
        for h in range(1, nharm+1):
            osc = np.exp(-2j*np.pi*f0*h*(start+n)/sr)
            row.append(2*abs((seg*osc).sum())/wsum)
        ts.append(start/sr); amps.append(row)
    return np.array(ts), np.array(amps)

def mod_spectrum(t, sig, label):
    """Spectrum of a control-rate signal (envelope or pitch), detrended."""
    sig = sig - np.polyval(np.polyfit(t, sig, 3), t)  # remove slow drift
    dt = t[1]-t[0]
    n = len(sig)
    spec = np.abs(np.fft.rfft(sig*np.hanning(n)))/n*4
    fr = np.fft.rfftfreq(n, dt)
    mask = (fr > 0.3) & (fr < 25)
    top = np.argsort(spec[mask])[::-1][:5]
    fs = fr[mask][top]; amps = spec[mask][top]
    print(f"  {label}: std={sig.std():.4g}, p2p={np.percentile(sig,98)-np.percentile(sig,2):.4g}")
    print(f"    dominant rates: " + ", ".join(f"{f:.1f}Hz(a={a:.4g})" for f, a in zip(fs, amps)))
    return fr[mask], spec[mask]

def analyze_sustain(path, note_on, note_off, f0):
    sr, x = load(path)
    print(f"\n=== {path} (f0~{f0:.0f}Hz) ===")
    t, e = rms_env(x, sr)
    edb = db(e)
    # Onset shape: peak in first 400ms vs steady mean
    on_i = np.searchsorted(t, note_on)
    onset_win = (t >= note_on) & (t < note_on + 0.5)
    steady_win = (t >= note_on + 1.0) & (t < note_off - 0.5)
    peak_db = edb[onset_win].max()
    tpk = t[onset_win][np.argmax(edb[onset_win])]
    steady_db = edb[steady_win].mean()
    print(f"  onset peak {peak_db:.2f} dB at t={tpk-note_on:.3f}s after on; steady mean {steady_db:.2f} dB "
          f"-> post-onset drop {peak_db-steady_db:.2f} dB")
    # time to reach steady-3dB, envelope of first 1s in 50ms steps
    seg = (t >= note_on) & (t < note_on + 1.2)
    print("  envelope first 1.2s (dB rel steady): " +
          " ".join(f"{v:.1f}" for v in (edb[seg][::5] - steady_db)))
    # Sustain modulation
    st = steady_win
    mod_spectrum(t[st], edb[st], "level (dB)")
    # Pitch
    ts, f0s = pitch_track(x, sr, f0, note_on+1.0, note_off-0.5)
    cents = 1200*np.log2(f0s/np.median(f0s))
    mod_spectrum(ts, cents, "pitch (cents)")
    # Harmonics
    ts2, H = harmonic_tracks(x, sr, np.median(f0s), 8, note_on+1.0, note_off-0.5)
    Hdb = db(H)
    print("  harmonic mean levels (dB rel h1): " +
          " ".join(f"h{i+1}={v:.1f}" for i, v in enumerate(Hdb.mean(axis=0)-Hdb.mean(axis=0)[0])))
    print("  harmonic fluctuation std (dB):    " +
          " ".join(f"h{i+1}={v:.2f}" for i, v in enumerate(Hdb.std(axis=0))))
    # correlation between harmonics' fluctuations
    c12 = np.corrcoef(Hdb[:,0], Hdb[:,1])[0,1]
    c13 = np.corrcoef(Hdb[:,0], Hdb[:,2])[0,1]
    c14 = np.corrcoef(Hdb[:,0], Hdb[:,3])[0,1]
    print(f"  harm fluctuation corr: h1-h2 {c12:.2f}, h1-h3 {c13:.2f}, h1-h4 {c14:.2f}")
    # release
    rel = (t >= note_off) & (t < note_off + 1.0)
    r = edb[rel] - steady_db
    print("  release (dB rel steady, 50ms steps): " + " ".join(f"{v:.1f}" for v in r[::5]))

def analyze_transitions(path, times, f0s_seq, label):
    sr, x = load(path)
    print(f"\n=== {path} ({label}) ===")
    t, e = rms_env(x, sr, 5.0)
    edb = db(e)
    for i, tt in enumerate(times):
        win = (t >= tt - 0.15) & (t < tt + 0.25)
        pre = edb[(t >= tt-0.3) & (t < tt-0.05)].mean()
        dip = edb[win].min() - pre
        tdip = t[win][np.argmin(edb[win])] - tt
        print(f"  transition@{tt}s: pre {pre:.1f} dB, dip {dip:.1f} dB at {tdip*1000:+.0f}ms")
    # pitch through one transition
    f0a, f0b = f0s_seq
    tt = times[len(times)//2]
    ts, ff = pitch_track(x, sr, (f0a+f0b)/2, tt-0.12, tt+0.15, hop_ms=4)
    print(f"  pitch through transition@{tt}: " +
          " ".join(f"{1200*np.log2(f/f0a):+.0f}c" for f in ff[::2]))

if __name__ == "__main__":
    base = sys.argv[1] if len(sys.argv) > 1 else "swam_refs"
    D4 = 293.66
    analyze_sustain(f"{base}/sustain_mf.wav", 0.5, 5.5, D4)
    analyze_sustain(f"{base}/sustain_f.wav", 0.5, 5.5, D4)
    E4, Fs4, G4 = 329.63, 369.99, 392.0
    analyze_transitions(f"{base}/legato.wav", [1.5, 2.5, 3.5, 4.5], (Fs4, G4), "legato")
    analyze_transitions(f"{base}/detached.wav", [1.5, 2.5, 3.5, 4.5], (Fs4, G4), "detached")
    # staccato envelope
    sr, x = load(f"{base}/staccato.wav")
    t, e = rms_env(x, sr, 5.0)
    edb = db(e)
    on = 0.5
    win = (t >= on-0.02) & (t < on+0.5)
    print(f"\n=== staccato note 1 envelope (dB, 20ms steps from note-on) ===")
    print("  " + " ".join(f"{v:.1f}" for v in edb[win][::4]))
