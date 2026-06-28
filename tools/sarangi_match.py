#!/usr/bin/env python3
"""Sarangi sympathetic-string (tarab) measurement + fit.

The sym layer is now a bank of DRIVEN modal resonators (`SarangiResonator` in
`Packages/StarpadDSP`) excited by the viola audio. We fit ONE pitch-invariant
tarab timbre to `sarangi1.wav` — isolated plucks of the sympathetic strings.

Because a driven 0 dB-peak resonator's steady response at mode k equals the
drive energy there (the modal gain is unity at resonance), the measured
plucked tarab maps DIRECTLY onto the resonator params — no render-and-calibrate
loop is needed (unlike the plucked sitar fit):
  per-harmonic relative gain  -> falloff law + gainTrimDB
  per-harmonic decay time τ   -> decay/dampTilt law + decayTrim  (τ sets Q)
  body formants               -> the smoothed LTAS peaks
The ~26 plucks run up DIFFERENT tarab strings, so each pluck is measured
relative to its OWN f0 and pooled by harmonic index into a single timbre.

Subcommands:
  analyze    detect plucks + their f0s, print the pooled per-mode profile
  fit-init   measure -> pool -> write auditions/sarangi/init.json (TanpuraParams)
  report     drive sym-render with a WAV and write a spectrogram vs sarangi2

Only numpy/scipy. Reuses tanpura_match's heterodyne/IO/PNG. Atomic writes.
"""

import argparse
import json
import os
import subprocess
import sys

import numpy as np
from scipy import signal

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tanpura_match as tm  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SDIR = os.path.join(REPO, "auditions", "sarangi")
REF_PLUCK = os.path.join(REPO, "sarangi1.wav")   # isolated tarab plucks
REF_BOW = os.path.join(REPO, "sarangi2.wav")     # bowed (validation target)
INIT = os.path.join(SDIR, "init.json")
REF_MODEL = os.path.join(SDIR, "reference_model.json")
SYM_RENDER = os.path.join(REPO, "Packages", "StarpadDSP", ".build",
                          "release", "sym-render")

SR = tm.SR
SPAN = 1.2          # s of each pluck to measure (tarabs ring ~1–2 s)
N_HARM = 24         # the dark sarangi needs few modes


# ---------------------------------------------------------------------------
# Pluck detection + per-pluck f0

def detect_onsets(x, min_gap=0.18, thresh_rel=0.18):
    """Energy-rise onset detector (the tarab plucks). Returns onset times (s)."""
    hop = int(0.01 * SR)
    win = int(0.03 * SR)
    env = np.array([np.sqrt(np.mean(x[i:i + win] ** 2))
                    for i in range(0, len(x) - win, hop)])
    t = np.arange(len(env)) * 0.01
    peak = env.max() + 1e-12
    onsets, last = [], -10.0
    for i in range(1, len(env)):
        if (env[i] > thresh_rel * peak and env[i] > env[i - 1] * 1.3
                and t[i] - last > min_gap):
            onsets.append(round(float(t[i]), 3))
            last = t[i]
    return onsets


def pluck_f0(x, onset, fmin=80.0, fmax=1100.0):
    """Estimate the struck string's f0 from a short post-onset window: the
    strongest spectral peak in [fmin, fmax] (the dark tarabs are
    fundamental-dominated, so the strongest low peak is f0), refined."""
    i0 = int((onset + 0.02) * SR)
    i1 = min(len(x), i0 + int(0.30 * SR))
    seg = x[i0:i1]
    if len(seg) < 1024:
        return None
    w = seg * np.hanning(len(seg))
    sp = np.abs(np.fft.rfft(w, n=1 << 16))
    fr = np.fft.rfftfreq(1 << 16, 1 / SR)
    band = (fr >= fmin) & (fr <= fmax)
    f_peak = fr[band][int(np.argmax(sp[band]))]
    return float(tm.refine_f0(seg, f_peak, span_cents=50, step_cents=2))


# ---------------------------------------------------------------------------
# Per-pluck per-mode measurement (heterodyne, pooled across plucks)

def measure_pluck(x, onset, f0, n_harm=N_HARM):
    """Per-mode gain (dB) + decay τ (s) for one pluck, relative to its f0."""
    A = tm.measure_envelope_matrix(x, f0, n_harm=n_harm, sr=SR)  # [k, t]
    hop = tm.ENV_HOP
    s = int(onset / hop)
    e = int(min(len(x) / SR, onset + SPAN) / hop)
    gains = np.full(n_harm, -120.0)
    taus = np.full(n_harm, 0.0)
    for k in range(min(n_harm, A.shape[0])):
        seg = A[k][s:e]
        if len(seg) < 6:
            continue
        ipk = int(np.argmax(seg))
        pk = seg[ipk]
        if pk <= 1e-6:
            continue
        gains[k] = 20 * np.log10(pk)
        tail = seg[ipk:]
        if len(tail) > 6 and tail[0] > 1e-6:
            ldb = 20 * np.log10(np.maximum(tail, 1e-7) / tail[0])
            drop = np.where(ldb < -12)[0]
            end = drop[0] if len(drop) else len(tail)
            if end > 4:
                tt = np.arange(end) * hop
                yy = np.log(np.maximum(tail[:end], 1e-7))
                sl = np.polyfit(tt, yy, 1)[0]
                if sl < -0.05:
                    taus[k] = -1.0 / sl
    return gains, taus


def pool_profile(x, onsets, f0s, n_harm=N_HARM):
    """Pool per-mode (gain, τ) across all plucks into one pitch-invariant
    tarab timbre. Each pluck is normalized to its own peak mode before
    pooling so loud/quiet plucks weight equally; medians reject outliers."""
    G, T = [], []
    for onset, f0 in zip(onsets, f0s):
        if f0 is None or f0 < 60:
            continue
        g, t = measure_pluck(x, onset, f0, n_harm)
        if g.max() < -100:
            continue
        G.append(g - g.max())            # relative dB, peak = 0
        T.append(np.where(t > 0, t, np.nan))
    G = np.array(G)
    T = np.array(T)
    # median across plucks, ignoring missing modes
    with np.errstate(invalid="ignore"):
        gain_db = np.where(np.isfinite(G), G, np.nan)
        gain_db = np.nanmedian(gain_db, axis=0)
        tau_s = np.nanmedian(T, axis=0)
    gain_db = np.nan_to_num(gain_db, nan=-90.0)
    tau_s = np.nan_to_num(tau_s, nan=0.0)
    return gain_db, tau_s, len(G)


# ---------------------------------------------------------------------------
# Body formants from the smoothed long-term average spectrum

# The sym body filter is HARDCODED to 3 bands (SymBodyFilter.swift), so the
# fit emits exactly 3. The body-resonance region we must cover sits near
# ~2.45/2.78 kHz (measured in nearly every bowed sample) — the old fmax=1400
# Hz never reached it. We now go to 3 kHz and, if none of the auto-picked
# peaks lands in the body-resonance window, force the weakest band onto the
# strongest LTAS peak there so the seed always covers it.
BODY_RES_LO, BODY_RES_HI = 2300.0, 2900.0


def _ltas_log(x, fmin, fmax):
    f, Pxx = signal.welch(x, SR, nperseg=8192, noverlap=4096)
    band = (f >= fmin) & (f <= fmax)
    fb, pb = f[band], Pxx[band]
    return fb, signal.savgol_filter(np.log(pb + 1e-12), 31, 3)


def _pick_body(fb, sm, n=3):
    """Pick the n strongest smoothed-LTAS peaks as body formants; guarantee
    one lands in the ~2.3–2.9 kHz body-resonance window."""
    pk, props = signal.find_peaks(sm, distance=8, prominence=0.2)
    if len(pk) == 0:
        return [{"freq": 600.0, "gain": 1.0, "q": 4.0},
                {"freq": 1240.0, "gain": 0.45, "q": 6.0},
                {"freq": 2470.0, "gain": 0.4, "q": 8.0}]
    order = np.argsort(props["prominences"])[::-1][:n]
    sel = list(pk[order])
    # Ensure body-resonance coverage: if no picked peak is in the window,
    # swap the weakest pick for the strongest LTAS bin there.
    if not any(BODY_RES_LO <= fb[p] <= BODY_RES_HI for p in sel):
        win = np.where((fb >= BODY_RES_LO) & (fb <= BODY_RES_HI))[0]
        if len(win):
            best = win[int(np.argmax(sm[win]))]
            weakest = min(sel, key=lambda p: sm[p])
            sel[sel.index(weakest)] = best
    sel = sorted(sel)
    peak0 = sm[sel].max()
    out = []
    for i, p in enumerate(sel):
        gain = float(np.clip(np.exp((sm[p] - peak0) * 0.5), 0.15, 1.0))
        out.append({"freq": round(float(fb[p]), 1), "gain": round(gain, 3),
                    "q": round(4.0 + 1.5 * i, 2)})
    while len(out) < 3:
        out.append({"freq": 2470.0, "gain": 0.3, "q": 8.0})
    return out[:3]


def body_formants(x, n=3, fmin=180.0, fmax=3000.0):
    """3 body formants from one signal's smoothed LTAS (the consistent peaks
    across differently-pitched content are the body, not the strings)."""
    fb, sm = _ltas_log(x, fmin, fmax)
    return _pick_body(fb, sm, n)


def body_formants_multi(paths, n=3, fmin=180.0, fmax=3000.0):
    """Body formants from the AVERAGE normalized log-LTAS across several
    (pitch-diverse) recordings — harmonics smear out, the body envelope
    survives. The scale (sarangi4) sweeps pitch, so it resolves the body
    best; same-pitch sustained notes reinforce their own harmonics and are
    poor body sources on their own."""
    acc = None
    fb = None
    for pth in paths:
        if not os.path.exists(pth):
            continue
        fb, sm = _ltas_log(tm.load_wav_mono(pth), fmin, fmax)
        sm = sm - sm.max()
        acc = sm if acc is None else acc + sm
    if acc is None:
        return body_formants(tm.load_wav_mono(REF_PLUCK), n, fmin, fmax)
    return _pick_body(fb, acc, n)


def body_source_paths(source):
    """Resolve a --body-source name to the WAV paths used for the body fit."""
    if source == "pluck":
        return [REF_PLUCK]
    if source == "scale":                      # sarangi4: pitch-diverse
        return [os.path.join(REPO, "sarangi4.wav")]
    if source == "bowed":                      # all bowed refs (2..8)
        return [os.path.join(REPO, f"sarangi{i}.wav") for i in range(2, 9)]
    raise SystemExit(f"unknown --body-source {source!r}")


# ---------------------------------------------------------------------------
# Build a TanpuraParams from the pooled profile

def fit_laws(gain_db, tau_s, n_harm):
    """Fit the smooth falloff (gain ∝ k^−falloff) and decay (τ = decay·k^−tilt)
    laws, then leave the per-mode residual in gainTrimDB / decayTrim."""
    ks = np.arange(1, n_harm + 1)
    valid = gain_db > -60
    if valid.sum() >= 3:
        # gain_db ≈ -20·falloff·log10(k)  → slope of dB vs log10(k)
        sl = np.polyfit(np.log10(ks[valid]), gain_db[valid], 1)[0]
        falloff = float(np.clip(-sl / 20.0, 0.5, 4.0))
    else:
        falloff = 2.2
    tv = tau_s > 0
    if tv.sum() >= 3:
        # τ = decay·k^−tilt → log τ = log decay − tilt·log k
        co = np.polyfit(np.log(ks[tv]), np.log(np.maximum(tau_s[tv], 1e-3)), 1)
        damp_tilt = float(np.clip(-co[0], 0.0, 1.6))
        decay = float(np.clip(np.exp(co[1]), 0.3, 6.0))
    else:
        damp_tilt, decay = 0.5, 1.2
    # residual trims
    gain_trim = [0.0] * 64
    decay_trim = [1.0] * 64
    law_db = -20.0 * falloff * np.log10(ks)
    for k in range(n_harm):
        if gain_db[k] > -60:
            gain_trim[k] = float(np.clip(gain_db[k] - law_db[k], -40, 24))
        if tau_s[k] > 0:
            law_tau = decay * (k + 1) ** (-damp_tilt)
            decay_trim[k] = float(np.clip(tau_s[k] / law_tau, 0.1, 6.0))
    return falloff, decay, damp_tilt, gain_trim, decay_trim


def build_params(gain_db, tau_s, body, n_harm):
    falloff, decay, damp_tilt, gtrim, dtrim = fit_laws(gain_db, tau_s, n_harm)
    string = {
        "f0": 280.4, "level": 1.0,
        "falloff": round(falloff, 4), "pluckPos": 0.1,
        "decay": round(decay, 4), "dampTilt": round(damp_tilt, 4),
        "bloomDelay": 0.12, "bloomSkew": 0.5, "attackLevel": 0.4,
        "attackDecay": 0.04, "inharmonicity": 4e-5,
        "subLevelDB": -60.0, "subFalloff": 1.6, "subKneeH": 40.0,
        "gainTrimDB": gtrim, "peakTrim": [1.0] * 64, "decayTrim": dtrim,
    }
    p = {
        "harmonicCount": n_harm, "jivaDepth": 0.14, "jivaRate": 3.2,
        "jivaTilt": 0.30, "jivaConserve": 0.9, "jivaRateSpread": 0.30,
        "pitchDriftCents": 3.0, "pitchDriftRate": 0.8,
        "pluckVariationDB": 0.0, "noiseLevel": 0.0, "noiseDecay": 0.01,
        "noiseFreq": 900.0, "noiseQ": 1.0, "crossExcite": 0.0,
        "crossTolCents": 12.0, "panSpread": 0.4,
        "bodyDry": 0.5, "tiltDB": -3.0, "masterGain": 1.0,
        "roomWetDB": -60.0, "roomDecayS": 0.8, "roomDamp": 0.5,
        "roomPredelayMs": 2.0, "body": body,
        "strings": [json.loads(json.dumps(string)) for _ in range(4)],
    }
    return p


# ---------------------------------------------------------------------------
# Commands

def measure_all(x, n_harm):
    onsets = detect_onsets(x)
    f0s = [pluck_f0(x, o) for o in onsets]
    keep = [(o, f) for o, f in zip(onsets, f0s) if f and 60 < f < 1100]
    onsets = [o for o, _ in keep]
    f0s = [f for _, f in keep]
    gain_db, tau_s, n_used = pool_profile(x, onsets, f0s, n_harm)
    return onsets, f0s, gain_db, tau_s, n_used


# ===========================================================================
# TAIL-BASED FIT  (fit-tail)
#
# Estimate the sympathetic (tarab) string from ONLY the decaying TAILS of the
# ISOLATED plucks. The attack of a pluck is broadband pick noise unrelated to
# the string's resonance; the tail is the pure modal ring-down — the cleanest
# read of the string's resonance (per-mode decay τ), harmonics (per-mode gain),
# and body (the spectral coloration that survives into the tail).
#
# Hard facts about sarangi1.wav that shape this estimator (verified):
#   * Only ~10 of 25 plucks are ISOLATED (gap-to-next ≥ 0.55 s); the rest are
#     strummed 0.18–0.27 s apart and have NO clean tail.
#   * Usable range is ~28 dB (peak −8, floor −36 dBFS). In the tail only the
#     FUNDAMENTAL (and a weak, blooming 2nd harmonic) clears a 10 dB SNR bar;
#     k3+ are at/below the noise floor. So at most 2 modes carry a MEASURED
#     trim; higher modes are governed by the falloff/damping LAWS (a designer
#     choice this recording cannot constrain — annotated as such).
#   * The 2nd harmonic BLOOMS (rises then sustains, cross-string coupling), so
#     its τ is unmeasurable; we take its gain from the post-bloom plateau.
#
# Pipeline: octave-guarded f0 → per-mode local-floor SNR gate + Rician debias →
# amplitude-weighted robust (Huber) log-linear tail fit → guarded
# back-extrapolation to onset for gain → SNR-weighted pooling by harmonic index
# → body from the notched tail LTAS → explicit low-data law branch.
# ---------------------------------------------------------------------------

ISO_GAP = 0.55         # s, isolation threshold (decay-fit + gain set)
EARLY_GAP = 0.45       # s, early-tail augment set (gain-only, k1/k2)
SNR_GATE_DB = 8.0      # per-mode tail-start SNR over the local floor to be reliable
GAIN_INCL_DB = 5.0     # lower bar: a mode's gain enters the falloff pool (down-weighted)
DECAY_MARGIN_DB = 6.0  # fit the decay only above floor + this
MIN_TAIL_S = 0.060     # shortest decay span that yields a trusted τ
BLOOM_AFTER_S = 0.080  # last local-max later than this after t0 ⇒ bloom (τ dropped)
MAX_EXTRAP_EFOLDS = 1.5
MAX_BOOST_DB = 6.0
FLOOR_DBFS = -36.0     # measured envelope noise floor of sarangi1.wav
TAIL_SKIP_S = 0.120    # attack/bloom-clearing margin before the tail starts


def SarangiSymVoice_falloff():
    """Current baked seed falloff (the prior used when the data can't fit a
    falloff law). Read from SarangiParams.swift so it tracks the last bake."""
    try:
        swift = os.path.join(REPO, "Packages", "StarpadDSP", "Sources",
                             "StarpadDSP", "SarangiParams.swift")
        m = __import__("re").search(r'"falloff":\s*([0-9.]+)', open(swift).read())
        return float(m.group(1)) if m else 1.96
    except Exception:
        return 1.96


def _comb_energy(seg, f0):
    """Weighted summed harmonic-envelope energy of a pitch candidate (octave
    discriminator). Reuses the heterodyne; cheap coarse hop."""
    e = 0.0
    for k in (1, 2, 3, 4, 6, 8):
        f = k * f0
        if f > 0.45 * SR:
            continue
        e += tm.harmonic_envelope(seg, f, lp=0.10, hop=0.05).sum() / k
    return e


def pluck_f0_guarded(x, onset):
    """f0 with an OCTAVE GUARD: pick the strongest spectral peak, then choose
    among {f/2, f, f·2} by summed harmonic-comb energy (a fundamental-weak
    tarab can read up an octave; a subharmonic can read down). Reject < 250 Hz
    (the tarabs here are 330–930 Hz; this drops the spurious 100.5 Hz reading)."""
    i0 = int((onset + 0.02) * SR)
    i1 = min(len(x), i0 + int(0.30 * SR))
    seg = x[i0:i1]
    if len(seg) < 1024:
        return None
    w = seg * np.hanning(len(seg))
    sp = np.abs(np.fft.rfft(w, n=1 << 16))
    fr = np.fft.rfftfreq(1 << 16, 1 / SR)
    band = (fr >= 150.0) & (fr <= 1100.0)
    f_peak = fr[band][int(np.argmax(sp[band]))]
    tseg = x[i0:min(len(x), i0 + int(0.5 * SR))]   # longer window for the comb test
    cands = [f_peak / 2, f_peak, f_peak * 2]
    es = [_comb_energy(tseg, c) for c in cands]
    f0 = cands[int(np.argmax(es))]
    f0 = float(tm.refine_f0(seg, f0, span_cents=50, step_cents=2))
    return f0 if f0 >= 250.0 else None


def _robust_loglin(t, a, floor):
    """Amplitude-weighted, Rician-debiased, Huber-robust log-linear fit of a
    decaying envelope. Returns (slope, intercept, r2). Plain log-LSQ over-weights
    the noisy quiet tail and biases τ long (~3× at a 12 dB ratio) — the exact
    `measure_pluck` bug; amplitude weighting + Huber fixes it."""
    ad = np.sqrt(np.maximum(a * a - floor * floor, 0.0))   # Rician debias
    keep = ad > floor * 0.5
    t, ad = t[keep], ad[keep]
    if len(t) < 4:
        return None
    y = np.log(np.maximum(ad, 1e-9))
    w = ad.copy()
    slope = intc = 0.0
    for _ in range(3):
        W = np.sqrt(np.maximum(w, 1e-12))
        A = np.vstack([t, np.ones_like(t)]).T * W[:, None]
        sol, *_ = np.linalg.lstsq(A, y * W, rcond=None)
        slope, intc = float(sol[0]), float(sol[1])
        resid = y - (slope * t + intc)
        mad = np.median(np.abs(resid - np.median(resid))) + 1e-9
        delta = 1.5 * mad
        hub = np.where(np.abs(resid) <= delta, 1.0, delta / np.maximum(np.abs(resid), 1e-9))
        w = ad * hub
    yhat = slope * t + intc
    ss = 1.0 - np.sum((y - yhat) ** 2) / (np.sum((y - np.mean(y)) ** 2) + 1e-12)
    return slope, intc, float(ss)


def measure_pluck_tail(trace, onset, nxt, hop=tm.ENV_HOP, gain_only=False):
    """One mode's (snr_db, gain_db, tau, bloomed, tau_ok) from its heterodyne
    envelope `trace`. Returns None if the mode never clears the SNR gate.
    `gain_only` caps the decay window (early-tail augment plucks)."""
    s = int(onset / hop)
    e = int(min(nxt, onset + 1.6) / hop)
    seg = trace[s:e]
    if len(seg) < 8:
        return None
    # GLOBAL per-mode noise floor: 5th-pctl of this mode's envelope over the
    # WHOLE file (the 150 ms before the next onset is contaminated when a tarab
    # rings up to the next pluck — that overestimated the floor and killed SNR).
    floor = max(float(np.percentile(trace, 5)), 10 ** ((FLOOR_DBFS - 2) / 20))
    smooth = signal.medfilt(seg, 5)
    # tail start: just past this mode's own attack/bloom peak (adaptive).
    t_pk = int(np.argmax(smooth[:int(0.30 / hop)])) if len(smooth) > int(0.30 / hop) else int(np.argmax(smooth))
    t0 = int(np.clip(t_pk + int(0.04 / hop), int(TAIL_SKIP_S / hop), int(0.30 / hop)))
    if t0 >= len(seg) - 4:
        return None
    a_t0 = max(np.sqrt(max(smooth[t0] ** 2 - floor ** 2, 0.0)), 1e-9)
    snr_db = 20 * np.log10(a_t0 / floor)
    if snr_db < SNR_GATE_DB:
        return dict(snr_db=snr_db, gain_db=None, tau=None, bloomed=False, tau_ok=False)
    # BLOOM = a genuine SUSTAINED rise: the smoothed envelope reaches a peak
    # > 3 dB above the t0 level, > 80 ms after t0 (k2 rises/sustains via
    # cross-string coupling). A decaying mode's noisy local maxima don't qualify.
    look = smooth[t0:t0 + int(0.50 / hop)]
    bloomed = False
    if len(look) > 4:
        ipk = int(np.argmax(look))
        if look[ipk] > smooth[t0] * 10 ** (3.0 / 20) and ipk * hop > BLOOM_AFTER_S:
            bloomed = True
    if bloomed:
        pm = t0 + ipk
        plateau = np.median(seg[pm:min(len(seg), pm + int(0.10 / hop))])
        g = max(np.sqrt(max(plateau ** 2 - floor ** 2, 0.0)), 1e-9)
        return dict(snr_db=snr_db, gain_db=20 * np.log10(g), tau=None,
                    bloomed=True, tau_ok=False)
    # tail end: 12 dB debiased drop, capped at the gap and (gain_only) 0.30 s
    cap = len(seg)
    if gain_only:
        cap = min(cap, int(0.30 / hop))
    drop = np.where(20 * np.log10(np.maximum(smooth[t0:cap], 1e-7) / max(smooth[t0], 1e-7)) < -12)[0]
    t1 = t0 + (drop[0] if len(drop) else (cap - t0))
    # monotone tail: robust decay fit over samples above floor+6 dB
    abovef = np.where(seg[t0:t1] > floor * 10 ** (DECAY_MARGIN_DB / 20))[0]
    if len(abovef) < 4:
        return dict(snr_db=snr_db, gain_db=20 * np.log10(a_t0), tau=None,
                    bloomed=False, tau_ok=False)
    span = abovef[-1] + 1
    tt = np.arange(span) * hop
    fit = _robust_loglin(tt, seg[t0:t0 + span], floor)
    tau = None
    tau_ok = False
    if fit is not None:
        slope, intc, r2 = fit
        if slope < -0.05:
            tau = -1.0 / slope
            # Trust τ only on a LONG, clean span: short spans are floor-truncated
            # (bias τ low) and the envelopes BEAT (so R² is modest even when good).
            tau_ok = (span * hop >= 0.22) and (r2 >= 0.70) and (0.10 < tau < 1.0) \
                and not gain_only
    # gain: guarded back-extrapolation of the fitted exponential to the onset
    t0_to_onset = t0 * hop
    if tau and (t0_to_onset / tau) <= MAX_EXTRAP_EFOLDS:
        boost_db = min(MAX_BOOST_DB, 20 * np.log10(np.exp(t0_to_onset / tau)))
        gain_db = 20 * np.log10(a_t0) + boost_db
    else:
        gain_db = 20 * np.log10(a_t0)            # no/over-extrapolation ⇒ use t0 level
    return dict(snr_db=snr_db, gain_db=gain_db, tau=tau if tau_ok else None,
                bloomed=False, tau_ok=tau_ok, tau_raw=tau)


def early_tail_profile(x, plucks, n_harm, hop=tm.ENV_HOP):
    """Harmonic BALANCE + k1 decay from the EARLY tail — the post-attack-transient
    decay (mode-peak +30…+150 ms), NOT the deep tail. 'Tail ends' means *past the
    broadband pick attack*, not literally the last 100 ms: in the deep tail only k1
    survives, so the harmonic balance (→ falloff) must be read from the early tail
    where k2 is still above the floor (but the pluck noise is gone). Returns
    (rel_db[k] vs k1, k1_tau_s). Modes with <3 contributors are NaN."""
    rel = [[] for _ in range(n_harm)]
    k1_taus = []
    for o, nxt, f0 in plucks:
        A = tm.measure_envelope_matrix(x, f0, n_harm=n_harm)
        s = int(o / hop)
        def window_rms(k):
            tr = A[k]
            floor = max(float(np.percentile(tr, 5)), 10 ** ((FLOOR_DBFS - 2) / 20))
            seg = signal.medfilt(tr[s:int(min(nxt, o + 1.0) / hop)], 5)
            pk = int(np.argmax(seg[:int(0.30 / hop)]))
            w = seg[pk + int(0.03 / hop):pk + int(0.15 / hop)]
            w = w[w > floor]
            return (20 * np.log10(np.sqrt(np.mean(w ** 2))) if len(w) >= 4 else None,
                    pk, seg, floor)
        l1, pk1, seg1, floor1 = window_rms(0)
        if l1 is None:
            continue
        for k in range(n_harm):
            lk = window_rms(k)[0]
            if lk is not None and lk - l1 > -45:
                rel[k].append(lk - l1)
        # k1 early-decay τ over [peak+0.02, peak+0.20] above floor — the pluck's
        # PRIMARY (fast) decay phase. A plucked tarab has a fast initial loss
        # then a slower body/sympathetic sustain; the fast phase carries the
        # perceived ring length (the longer 0.30 s window catches the slow tail
        # and over-lengthens the ring vs the real, tighter pluck).
        tail = seg1[pk1 + int(0.02 / hop):pk1 + int(0.20 / hop)]
        tail = tail[tail > floor1]
        if len(tail) >= 6:
            sl = np.polyfit(np.arange(len(tail)) * hop, np.log(tail), 1)[0]
            if sl < -0.05:
                k1_taus.append(-1.0 / sl)
    prof = np.full(n_harm, np.nan)
    for k in range(n_harm):
        if len(rel[k]) >= 3:
            prof[k] = float(np.median(rel[k]))
    k1_tau = float(np.median(k1_taus)) if k1_taus else 0.19
    return prof, k1_tau


def body_from_tails(x, plucks, f0s, n=3):
    """3 body formants from the pooled TAIL-segment LTAS of the isolated plucks
    (absolute Hz), with each pluck's k1/k2 notched out (±30 cents) so the
    dominant low string modes don't masquerade as body formants. Returns
    (formants, fb, curve_db) — curve_db (rel max) also body-corrects the gains."""
    acc = None
    fb = None
    cnt = 0
    for (o, nxt), f0 in zip(plucks, f0s):
        s = int((o + 0.18) * SR)
        e = int(min(nxt - 0.03, o + 1.2) * SR)
        seg = x[s:e]
        if len(seg) < 4096:
            continue
        f, P = signal.welch(seg, SR, nperseg=4096, noverlap=2048)
        logp = np.log(P + 1e-12)
        for k in (1, 2):
            fc = k * f0
            nb = (f >= fc * 2 ** (-30 / 1200)) & (f <= fc * 2 ** (30 / 1200))
            logp[nb] = np.nan
        good = np.isfinite(logp)
        logp = np.interp(f, f[good], logp[good])
        band = (f >= 180) & (f <= 3500)
        sm = signal.savgol_filter(logp[band], 31, 3)
        sm = sm - sm.max()
        acc = sm if acc is None else acc + sm
        fb = f[band]
        cnt += 1
    if acc is None:
        return body_formants(x, n), None, None
    acc = acc / cnt
    return _pick_body(fb, acc, n), fb, acc * 4.342945   # curve in dB


def cmd_fit_tail(args):
    os.makedirs(os.path.join(SDIR, "work"), exist_ok=True)
    x = tm.load_wav_mono(REF_PLUCK)
    n_harm = args.harmonics
    hop = tm.ENV_HOP
    onsets = detect_onsets(x)
    bounds = onsets + [len(x) / SR]
    gaps = [bounds[i + 1] - bounds[i] for i in range(len(onsets))]

    # two-tier selection + octave-guarded f0
    primary, early = [], []
    for o, g in zip(onsets, gaps):
        f0 = pluck_f0_guarded(x, o)
        if f0 is None:
            continue
        nxt = o + g
        if g >= ISO_GAP:
            primary.append((o, nxt, f0))
        elif g >= EARLY_GAP:
            early.append((o, nxt, f0))
    print(f"isolated(primary) {len(primary)}  early-tail(gain-only) {len(early)}  "
          f"(rejected octave/<250Hz or strummed)")

    # per-pluck per-mode measurement
    gains = [[] for _ in range(n_harm)]      # (gain_db, snr) body-corrected, k1-normalized
    taus = [[] for _ in range(n_harm)]
    bloom_log = []
    body, fb, body_db = body_from_tails(x, [(o, nxt) for o, nxt, _ in primary],
                                        [f for _, _, f in primary])

    def body_at(fa):
        return float(np.interp(fa, fb, body_db)) if fb is not None else 0.0

    for tag, plist in (("primary", primary), ("early", early)):
        for o, nxt, f0 in plist:
            A = tm.measure_envelope_matrix(x, f0, n_harm=n_harm)
            per = []
            for k in range(n_harm):
                r = measure_pluck_tail(A[k], o, nxt, hop, gain_only=(tag == "early"))
                per.append(r)
            # normalize this pluck's gains to its k1 (the reference mode)
            g1 = per[0]["gain_db"] if per[0] and per[0]["gain_db"] is not None else None
            if g1 is None:
                continue
            g1c = g1 - body_at(f0)
            for k in range(n_harm):
                r = per[k]
                if r is None or r.get("gain_db") is None or r["snr_db"] < GAIN_INCL_DB:
                    continue
                gc = r["gain_db"] - body_at((k + 1) * f0)      # body-correct
                gains[k].append((gc - g1c, r["snr_db"]))
                if r.get("tau") is not None and tag == "primary":
                    taus[k].append(r["tau"])
                if k == 1 and r.get("bloomed"):
                    bloom_log.append(round(f0, 1))

    # SNR-weighted pooling + contributor gate
    n_pl = len(primary) + len(early)
    min_contrib = 3
    pooled_g = np.full(n_harm, np.nan)
    pooled_t = np.full(n_harm, np.nan)
    pooled_snr = np.full(n_harm, np.nan)
    contrib = np.zeros(n_harm, int)
    iqr = np.full(n_harm, np.nan)
    for k in range(n_harm):
        obs = gains[k]
        contrib[k] = len(obs)
        if len(obs) >= min_contrib:
            vals = np.array([v for v, _ in obs])
            snrs = np.array([s for _, s in obs])
            w = np.clip((snrs - 5.0) / 15.0, 0.05, 1.0)
            order = np.argsort(vals)
            vs, ws = vals[order], w[order]
            cum = np.cumsum(ws)
            if cum[-1] > 0:
                pooled_g[k] = float(vs[np.searchsorted(cum, 0.5 * cum[-1])])
                iqr[k] = float(np.percentile(vals, 75) - np.percentile(vals, 25))
                pooled_snr[k] = float(np.median(snrs))
        if len(taus[k]) >= 2:
            pooled_t[k] = float(np.median(taus[k]))

    # TRUSTED = pooled, ≥3 plucks, median SNR over the full gate. GAIN-INCLUDED
    # (borderline, ≥5 dB) modes still inform the falloff law but are flagged.
    rel = np.where(np.isfinite(pooled_g))[0]
    trusted = np.where(np.isfinite(pooled_g) & (pooled_snr >= SNR_GATE_DB))[0]
    print(f"\nreliable-mode audit: trusted(SNR≥{SNR_GATE_DB} dB,≥{min_contrib} plucks)"
          f"={len(trusted)}  gain-included(≥{GAIN_INCL_DB} dB)={len(rel)}")
    print("mode  gain_dB  tau_s  medSNR  #plucks  IQR_dB")
    for k in range(min(n_harm, 8)):
        if contrib[k] == 0 and not np.isfinite(pooled_g[k]):
            continue
        gs = f"{pooled_g[k]:6.1f}" if np.isfinite(pooled_g[k]) else "   -- "
        ts = f"{pooled_t[k]:5.2f}" if np.isfinite(pooled_t[k]) else "  -- "
        sn = f"{pooled_snr[k]:5.1f}" if np.isfinite(pooled_snr[k]) else "  -- "
        iq = f"{iqr[k]:4.1f}" if np.isfinite(iqr[k]) else " -- "
        print(f"  k{k+1:2d}  {gs}   {ts}  {sn}   {contrib[k]:5d}   {iq}")
    if bloom_log:
        print(f"bloom (τ dropped) on k2 of plucks f0≈ {bloom_log}")
    surviving = len(trusted)

    # --- build params from the EARLY tail (post-attack, where the harmonic
    # balance is still measurable) — NOT the deep tail (k1-only). This is what
    # makes the fit warm/fundamental-dominated and matches the real pluck: the
    # deep-tail-only fit left the upper modes at the bright falloff floor.
    eb, k1_tau = early_tail_profile(x, primary, n_harm)
    ebk = np.where(np.isfinite(eb))[0]
    print(f"\nearly-tail harmonic balance (rel k1): "
          + "  ".join(f"k{k+1} {eb[k]:+.1f}dB" for k in ebk))
    if len(ebk) >= 2:
        falloff = float(np.clip(-np.polyfit(np.log10(ebk + 1), eb[ebk], 1)[0] / 20.0, 0.5, 4.0))
        falloff_note = f"fit from early-tail balance (k2={eb[1]:+.1f} dB)"
    else:
        falloff = float(SarangiSymVoice_falloff())
        falloff_note = "PINNED to prior (no measurable k2 even in the early tail)"
    decay = float(np.clip(k1_tau, 0.1, 6.0))     # k1 early-decay (~0.18–0.19 s)
    # Per-mode decay (dampTilt) is UNMEASURABLE: k2 blooms (cross-string
    # coupling) so its τ reads slower than k1 (non-physical). Set a modest
    # positive tilt so the modeled tail goes fundamental-dominated like the real
    # one (upper modes ring down faster), tuned to reproduce the pluck's ring.
    damp_tilt = 0.45
    tilt_note = "0.45 — chosen (per-mode τ unmeasurable: k2 blooms); keeps the tail fundamental-dominated"

    # Residual trims: the falloff law already captures k1/k2; emit the small
    # residual for measured modes, law-only (0 / 1) above. decayTrim stays 1
    # (no trustworthy per-mode decay shape).
    law_db = -20.0 * falloff * np.log10(np.arange(1, n_harm + 1))
    gtrim = [0.0] * 64
    dtrim = [1.0] * 64
    for k in ebk:
        gtrim[k] = float(np.clip(eb[k] - law_db[k], -40, 24))

    string = {
        "f0": 280.4, "level": 1.0, "falloff": round(falloff, 4), "pluckPos": 0.1,
        "decay": round(decay, 4), "dampTilt": round(damp_tilt, 4),
        "bloomDelay": 0.12, "bloomSkew": 0.5, "attackLevel": 0.4,
        "attackDecay": 0.04, "inharmonicity": 4e-5,
        "subLevelDB": -60.0, "subFalloff": 1.6, "subKneeH": 40.0,
        "gainTrimDB": gtrim, "peakTrim": [1.0] * 64, "decayTrim": dtrim,
    }
    p = {
        "harmonicCount": n_harm, "jivaDepth": 0.0, "jivaRate": 3.2,
        "jivaTilt": 0.30, "jivaConserve": 0.9, "jivaRateSpread": 0.30,
        "pitchDriftCents": 3.0, "pitchDriftRate": 0.8,
        "pluckVariationDB": 0.0, "noiseLevel": 0.0, "noiseDecay": 0.01,
        "noiseFreq": 900.0, "noiseQ": 1.0, "crossExcite": 0.0,
        "crossTolCents": 12.0, "panSpread": 0.4,
        "bodyDry": 0.5, "tiltDB": -3.0, "masterGain": 1.0,
        "roomWetDB": -60.0, "roomDecayS": 0.8, "roomDamp": 0.5,
        "roomPredelayMs": 2.0, "body": body,
        "strings": [json.loads(json.dumps(string)) for _ in range(4)],
        "_tail_fit": {
            "reliable_modes": surviving, "falloff_note": falloff_note,
            "tilt_note": tilt_note,
            "decay_note": "ABSOLUTE decay NOT deployed (SoundPreset symDecay=2.0, "
                          "SarangiSymVoice.decay=0.279 override it). Only decayTrim "
                          "shape + falloff + body reach the resonator. k1 τ is also "
                          "biased short by floor truncation — not the free-decay.",
            "high_mode_note": "gainTrimDB/decayTrim for k>reliable are 0/1 (law-only); "
                              "brightness/partial-count/jawari are designer-set in "
                              "SoundPreset, not measurable from sarangi1.",
            "n_primary": len(primary), "n_early": len(early),
            "bloom_k2_f0": bloom_log,
        },
    }
    tm.atomic_write_json(INIT, p)
    print(f"\nfalloff {round(falloff,4)} ({falloff_note})")
    print(f"decay   {round(decay,4)} s  dampTilt {round(damp_tilt,4)} ({tilt_note})")
    print(f"body (notched tail LTAS) {body}")
    print(f"wrote {INIT}")


def cmd_analyze(args):
    x = tm.load_wav_mono(REF_PLUCK)
    onsets, f0s, gain_db, tau_s, n_used = measure_all(x, args.harmonics)
    print(f"{len(onsets)} plucks; f0s (Hz): "
          + ", ".join(f"{f:.0f}" for f in f0s))
    print(f"pooled over {n_used} plucks — per-mode (k: gain dB / τ s):")
    for k in range(min(args.harmonics, 24)):
        print(f"  k{k+1:2d}  {gain_db[k]:6.1f} dB   {tau_s[k]:5.2f} s")
    print("body formants:", body_formants(x))


def cmd_fit_init(args):
    os.makedirs(os.path.join(SDIR, "work"), exist_ok=True)
    x = tm.load_wav_mono(REF_PLUCK)
    n_harm = args.harmonics
    # The per-mode tarab gain/decay arrays come ONLY from sarangi1's plucks
    # (the isolated sympathetic strings — SWAM is bowed, so they aren't
    # live-reproducible). The BODY formants come from --body-source: the
    # pitch-diverse scale (default) resolves the body envelope best.
    onsets, f0s, gain_db, tau_s, n_used = measure_all(x, n_harm)
    body = body_formants_multi(body_source_paths(args.body_source))
    p = build_params(gain_db, tau_s, body, n_harm)
    tm.atomic_write_json(INIT, p)
    tm.atomic_write_json(REF_MODEL, {
        "source": "sarangi1.wav", "body_source": args.body_source,
        "onsets": onsets, "f0s": f0s,
        "n_pooled": n_used, "harm_gain_db": gain_db.tolist(),
        "harm_tau_s": tau_s.tolist(), "body": body})
    print(f"fit {n_used}/{len(onsets)} plucks  falloff {p['strings'][0]['falloff']}"
          f"  decay {p['strings'][0]['decay']}  dampTilt {p['strings'][0]['dampTilt']}")
    print(f"body ({args.body_source}) {body}")
    print(f"wrote {INIT}\nwrote {REF_MODEL}")


def cmd_report(args):
    """Drive sym-render with a WAV (default: the bowed sarangi2.wav) through a
    chromatic tarab bank using the fitted params, and write a spectrogram of
    the resulting halo beside the bowed reference."""
    params = json.load(open(args.params)) if args.params else None
    drive = args.drive or REF_BOW
    # A chromatic tarab bank around the bowed note's range.
    base = 196.0
    freqs = [round(base * 2 ** (i / 12.0), 2) for i in range(24)]
    out_wav = args.out_wav or os.path.join(SDIR, "work", "halo.wav")
    spec = {"driveWav": drive, "frequencies": freqs,
            "playedNotes": freqs, "out": out_wav}
    if params is not None:
        spec["sarangiParams"] = params
    sp = out_wav + ".spec.json"
    os.makedirs(os.path.dirname(out_wav), exist_ok=True)
    tm.atomic_write_json(sp, spec)
    r = subprocess.run([SYM_RENDER, sp, "--mono"], capture_output=True, text=True)
    os.remove(sp)
    if r.returncode != 0:
        raise SystemExit(f"sym-render failed: {r.stderr}")
    halo = tm.load_wav_mono(out_wav)
    bow = tm.load_wav_mono(drive)
    img_b = tm.logspec_image(bow, fmin=120, fmax=8000)
    img_h = tm.logspec_image(halo, fmin=120, fmax=8000)
    h = min(img_b.shape[0], img_h.shape[0])
    w = min(img_b.shape[1], img_h.shape[1])
    gap = np.full((4, w, 3), 255, np.uint8)
    out = args.out or os.path.join(SDIR, "report.png")
    tm.write_png(out, np.vstack([img_b[:h, :w], gap, img_h[:h, :w]]))
    print(f"halo -> {out_wav}\nwrote {out}  (top: bowed ref, bottom: halo)")


# ---------------------------------------------------------------------------
# Per-sample reference analysis (multi-reference LIVE-match prep)
#
# The live loop (`sarangi_iterate.py`) drives real SWAM + the sym halo and
# compares the post-FX render to each bowed sample. To author a fair score per
# reference we need, per file: the note(s) to play (MIDI + residual cents),
# the voiced/scoring window, the vibrato rate+depth, and the full-range LTAS
# formants (incl. the ~2.45/2.78 kHz body resonance the old <1.4 kHz body fit
# missed). sarangi1 (plucks) is offline-only — SWAM is bowed, so its tarab
# pluck can't be live-reproduced; it stays the per-mode decay measurement.

REFS_DIR = os.path.join(SDIR, "refs")

# name -> (filename, role). roles: anchor (always in the minibatch), primary
# (rotating timbre targets), validation (rescored on elites only), pluck
# (offline tarab-decay measurement only — not live-reproducible).
REF_FILES = [
    ("sarangi1", "sarangi1.wav", "pluck"),
    ("sarangi2", "sarangi2.wav", "primary"),
    ("sarangi3", "sarangi3.wav", "anchor"),
    ("sarangi4", "sarangi4.wav", "validation"),
    ("sarangi5", "sarangi5.wav", "primary"),
    ("sarangi6", "sarangi6.wav", "primary"),
    ("sarangi7", "sarangi7.wav", "validation"),
    ("sarangi8", "sarangi8.wav", "validation"),
]

F0_HOP = 0.02            # s, f0-track hop
F0_MIN, F0_MAX = 110.0, 700.0


def hz_to_midi_cents(f0):
    m = 69.0 + 12.0 * np.log2(f0 / 440.0)
    midi = int(round(m))
    return midi, round((m - midi) * 100.0, 1)


def f0_track(x, sr=SR, hop=F0_HOP, fmin=F0_MIN, fmax=F0_MAX):
    """Frame-wise f0 (Hz, nan when unvoiced) + RMS via normalized
    autocorrelation with parabolic refine. Robust for legato bowed notes
    where energy onsets are weak (so pitch, not energy, segments notes)."""
    win = int(0.046 * sr)            # ~46 ms (≥ 2 periods at fmin)
    H = int(hop * sr)
    lo = max(1, int(sr / fmax))
    hi = int(sr / fmin)
    times, f0s, rms = [], [], []
    for i in range(0, len(x) - win, H):
        seg = x[i:i + win].astype(np.float64)
        e = float(np.sqrt(np.mean(seg ** 2)))
        times.append(i / sr)
        rms.append(e)
        if e < 1e-4:
            f0s.append(np.nan)
            continue
        seg = (seg - seg.mean()) * np.hanning(len(seg))
        ac = np.correlate(seg, seg, "full")[len(seg) - 1:]
        acn = ac / (ac[0] + 1e-12)
        h = min(hi, len(acn) - 2)
        if h <= lo:
            f0s.append(np.nan)
            continue
        peak = lo + int(np.argmax(acn[lo:h]))
        a, b, c = acn[peak - 1], acn[peak], acn[peak + 1]
        denom = a - 2 * b + c
        lag = peak + (0.5 * (a - c) / denom if abs(denom) > 1e-9 else 0.0)
        if acn[peak] < 0.3 or lag <= 0:
            f0s.append(np.nan)
            continue
        f0s.append(sr / lag)
    return np.array(times), np.array(f0s), np.array(rms)


def voiced_span(times, f0, rms, rel=0.15):
    """First/last frame that is both energetic (> rel·peak RMS) and voiced."""
    if len(rms) == 0:
        return None
    thr = rel * float(np.max(rms))
    ok = (rms > thr) & np.isfinite(f0)
    idx = np.where(ok)[0]
    if len(idx) < 3:
        return None
    return float(times[idx[0]]), float(times[idx[-1]])


def analyze_vibrato(times, f0):
    """Vibrato rate (Hz) + depth (cents, 90th-pct deviation) over the
    voiced f0 track. Phase is irrelevant to specres (time-smeared, depth is
    scored as a statistic) — we only need rate+depth to author the glides."""
    ok = np.isfinite(f0)
    if ok.sum() < 8:
        return {"rate_hz": 0.0, "depth_cents": 0.0}
    t = times[ok]
    cents = 1200.0 * np.log2(f0[ok] / np.nanmedian(f0[ok]))
    # remove slow drift (~100 ms moving average), keep the ~5 Hz wobble
    k = max(3, int(round(0.1 / (np.median(np.diff(t)) + 1e-9))))
    cents = cents - np.convolve(cents, np.ones(k) / k, "same")
    hop = float(np.median(np.diff(t)))
    sp = np.abs(np.fft.rfft(cents * np.hanning(len(cents))))
    fr = np.fft.rfftfreq(len(cents), hop)
    band = (fr >= 3.0) & (fr <= 9.0)
    rate = float(fr[band][int(np.argmax(sp[band]))]) if band.any() else 0.0
    depth = float(np.percentile(np.abs(cents), 90))
    return {"rate_hz": round(rate, 2), "depth_cents": round(depth, 1)}


def segment_notes(times, f0, min_dur=0.30):
    """Quantize voiced f0 to the nearest semitone, return stable runs as
    note segments (for the scale / multi-note refs). One segment for a
    sustained note; several for sarangi4/7/8."""
    semis = np.full(len(f0), np.nan)
    ok = np.isfinite(f0)
    semis[ok] = np.round(69.0 + 12.0 * np.log2(f0[ok] / 440.0))
    segs, i, n = [], 0, len(f0)
    while i < n:
        if not np.isfinite(semis[i]):
            i += 1
            continue
        j, cur = i, semis[i]
        while j < n and np.isfinite(semis[j]) and abs(semis[j] - cur) < 1.0:
            j += 1
        t0, t1 = float(times[i]), float(times[min(j, n - 1)])
        run = f0[i:j][np.isfinite(f0[i:j])]
        if t1 - t0 >= min_dur and len(run):
            mf = float(np.median(run))
            midi, cents = hz_to_midi_cents(mf)
            segs.append({"at": round(t0, 3), "dur": round(t1 - t0, 3),
                         "f0": round(mf, 2), "midi": midi, "cents": cents})
        i = j
    return segs


def ltas_formants(x, n=8, fmin=200.0, fmax=4000.0):
    """Full-range smoothed-LTAS formant peaks (relative dB to the loudest).
    Unlike `body_formants` (≤1400 Hz) this reaches the ~2.45/2.78 kHz body
    resonance the bowed samples show."""
    f, P = signal.welch(x, SR, nperseg=8192, noverlap=4096)
    band = (f >= fmin) & (f <= fmax)
    fb, pb = f[band], P[band]
    sm = signal.savgol_filter(np.log(pb + 1e-12), 31, 3)
    pk, props = signal.find_peaks(sm, distance=6, prominence=0.2)
    if len(pk) == 0:
        return []
    order = np.argsort(props["prominences"])[::-1][:n]
    pk = sorted(pk[order])
    peak0 = sm[pk].max()
    return [{"freq": round(float(fb[p]), 1),
             "rel_db": round(float((sm[p] - peak0) * 4.342945), 2)} for p in pk]


def analyze_ref(name, fname, role):
    x = tm.load_wav_mono(os.path.join(REPO, fname))
    dur = len(x) / SR
    model = {"name": name, "source": fname, "role": role,
             "duration": round(dur, 3),
             "ltas_formants": ltas_formants(x)}
    if role == "pluck":
        # offline-only tarab decay; the per-mode arrays come from fit-init.
        model["note"] = "isolated tarab plucks — offline measurement only; "\
                         "not live-reproducible (SWAM is bowed)."
        return x, model
    times, f0, rms = f0_track(x)
    span = voiced_span(times, f0, rms)
    if span is None:
        model["error"] = "no voiced span found"
        return x, model
    t0, t1 = span
    model["voiced"] = [round(t0, 3), round(t1, 3)]
    # scoring window: skip the attack & the release tail
    w0 = round(min(t1 - 0.2, t0 + 0.15), 3)
    w1 = round(max(w0 + 0.2, t1 - 0.1), 3)
    model["window"] = [w0, w1]
    segs = segment_notes(times, f0)
    model["segments"] = segs
    # primary note = the longest stable segment (or median over the window)
    in_win = np.isfinite(f0) & (times >= w0) & (times <= w1)
    mf = float(np.median(f0[in_win])) if in_win.any() else (
        segs[0]["f0"] if segs else float(np.nanmedian(f0)))
    midi, cents = hz_to_midi_cents(mf)
    model["f0"] = round(mf, 2)
    model["midi"] = midi
    model["cents"] = cents
    model["vibrato"] = analyze_vibrato(times[in_win], f0[in_win]) if in_win.any() \
        else analyze_vibrato(times, f0)
    model["n_segments"] = len(segs)
    return x, model


def cmd_refs(args):
    os.makedirs(REFS_DIR, exist_ok=True)
    sel = args.only.split(",") if args.only else [n for n, _, _ in REF_FILES]
    for name, fname, role in REF_FILES:
        if name not in sel:
            continue
        src = os.path.join(REPO, fname)
        if not os.path.exists(src):
            print(f"  ! {fname} missing — skip")
            continue
        x, model = analyze_ref(name, fname, role)
        d = os.path.join(REFS_DIR, name)
        os.makedirs(d, exist_ok=True)
        tm.atomic_write_json(os.path.join(d, "model.json"), model)
        # self-contained copy of the reference for the loop to score against
        import shutil
        shutil.copy(src, os.path.join(d, "reference.wav"))
        try:
            tm.write_png(os.path.join(d, "overlay.png"),
                         tm.logspec_image(x, fmin=120, fmax=8000))
        except Exception as e:  # noqa: BLE001
            print(f"    (spectrogram failed: {e})")
        if role == "pluck":
            print(f"  {name:9s} [{role}]  (offline-only)  "
                  f"formants {[f['freq'] for f in model['ltas_formants'][:4]]}")
        elif "error" in model:
            print(f"  {name:9s} [{role}]  ERROR: {model['error']}")
        else:
            vb = model["vibrato"]
            print(f"  {name:9s} [{role:10s}] f0 {model['f0']:6.1f}Hz "
                  f"(MIDI {model['midi']}{model['cents']:+.0f}c) "
                  f"win {model['window']} segs {model['n_segments']} "
                  f"vib {vb['rate_hz']}Hz/{vb['depth_cents']}c "
                  f"fmts {[f['freq'] for f in model['ltas_formants'][:5]]}")
    print(f"wrote {REFS_DIR}/<name>/{{model.json,reference.wav,overlay.png}}")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(required=True)
    p = sub.add_parser("analyze")
    p.add_argument("--harmonics", type=int, default=N_HARM)
    p.set_defaults(fn=cmd_analyze)
    p = sub.add_parser("fit-init")
    p.add_argument("--harmonics", type=int, default=N_HARM)
    p.add_argument("--body-source", default="scale",
                   choices=["pluck", "scale", "bowed"],
                   help="where the 3 body formants are measured "
                   "(scale=sarangi4 pitch-diverse, best; default)")
    p.set_defaults(fn=cmd_fit_init)
    p = sub.add_parser("fit-tail", help="fit the tarab string from ONLY the "
                       "decaying tails of the isolated plucks (resonance + "
                       "harmonics + body); writes auditions/sarangi/init.json")
    p.add_argument("--harmonics", type=int, default=N_HARM)
    p.set_defaults(fn=cmd_fit_tail)
    p = sub.add_parser("report")
    p.add_argument("--params", default=INIT)
    p.add_argument("--drive", default=None)
    p.add_argument("--out-wav", default=None)
    p.add_argument("-o", "--out", default=None)
    p.set_defaults(fn=cmd_report)
    p = sub.add_parser("refs", help="per-sample reference analysis for the "
                       "live multi-reference match")
    p.add_argument("--only", default=None,
                   help="comma-separated subset, e.g. sarangi3,sarangi6")
    p.set_defaults(fn=cmd_refs)
    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
