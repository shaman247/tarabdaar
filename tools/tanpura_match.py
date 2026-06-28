#!/usr/bin/env python3
"""Tanpura reference measurement + perceptual loss for the matching loop.

The tanpura's defining characteristic is that a pluck splits into harmonics
that peak at different times. Everything here is built around measuring that
directly: each harmonic of each string is heterodyned out of the recording
into an envelope A_k(t), and both calibration (fit the model from the
reference) and the loss (compare a candidate render against the reference)
operate on those per-harmonic envelopes.

Subcommands:
  decode-ref   tanpura.mp3 -> auditions/tanpura/reference.wav (afconvert)
  calibrate    measure f0s, pluck schedule, per-harmonic envelopes ->
               reference_model.json + reference_harmonics.npz
  fit-init     fit TanpuraParams (laws + per-harmonic trims) from the
               measurement -> measured initial params JSON
  loss         score a candidate WAV against the reference measurement
  spectrogram  side-by-side log-frequency spectrogram PNG (ref vs candidate)
  make-score   emit an AuditionScore JSON for in-app verification

Only numpy/scipy are used (no librosa/matplotlib). All file writes are
atomic (.tmp -> rename).
"""

import argparse
import json
import os
import shutil
import struct
import subprocess
import sys
import wave
import zlib

import numpy as np
from scipy import signal

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TDIR = os.path.join(REPO, "auditions", "tanpura")
REF_WAV = os.path.join(TDIR, "reference.wav")
REF_MODEL = os.path.join(TDIR, "reference_model.json")
REF_NPZ = os.path.join(TDIR, "reference_harmonics.npz")

SR = 44100
N_HARM = 24            # harmonics measured/synthesized per string
ENV_HOP = 0.010        # s, hop of the per-harmonic envelope traces
ENV_LP = 0.060         # s, box lowpass on heterodyned envelopes
SEG_LEN = 2.4          # s, per-pluck analysis segment length

# String roles in model order: Pa (G3), sa (C4), sa (C4), SA (C3).
CANDIDATE_F0 = [196.00, 261.63, 261.63, 130.81]
STRING_NAMES = ["Pa(G3)", "sa(C4)", "sa(C4)", "SA(C3)"]


# ---------------------------------------------------------------------------
# I/O helpers

def atomic_write(path, data):
    tmp = path + ".tmp"
    mode = "wb" if isinstance(data, bytes) else "w"
    with open(tmp, mode) as f:
        f.write(data)
    os.replace(tmp, path)


def atomic_write_json(path, obj):
    atomic_write(path, json.dumps(obj, indent=1, sort_keys=True))


def load_wav_mono(path):
    w = wave.open(path, "rb")
    sr = w.getframerate()
    ch = w.getnchannels()
    if w.getsampwidth() != 2:
        raise SystemExit(f"{path}: expected 16-bit PCM")
    x = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)
    w.close()
    x = x.astype(np.float64) / 32768.0
    if ch > 1:
        x = x.reshape(-1, ch).mean(axis=1)
    if sr != SR:
        raise SystemExit(f"{path}: expected {SR} Hz, got {sr}")
    return x


# ---------------------------------------------------------------------------
# Per-harmonic envelope measurement (heterodyne)

def harmonic_envelope(x, freq, sr=SR, lp=ENV_LP, hop=ENV_HOP):
    """|lowpass(x * e^{-j2πft})| sampled every `hop` seconds.

    A box lowpass via cumsum keeps this fast for many harmonics.
    """
    n = len(x)
    t = np.arange(n) / sr
    z = x * np.exp(-2j * np.pi * freq * t)
    k = max(8, int(lp * sr))
    c = np.cumsum(z)
    smoothed = np.empty(n - k, dtype=complex)
    smoothed[:] = (c[k:] - c[:-k]) / k
    hop_n = int(hop * sr)
    return 2.0 * np.abs(smoothed[::hop_n])


def measure_envelope_matrix(x, f0, n_harm=N_HARM, sr=SR):
    """A[k, t]: envelope of harmonic k+1 of f0 over the whole signal."""
    rows = []
    for k in range(1, n_harm + 1):
        f = k * f0
        if f > 0.45 * sr:
            rows.append(np.zeros(len(rows[0]) if rows else 1))
            continue
        rows.append(harmonic_envelope(x, f, sr=sr))
    m = min(len(r) for r in rows)
    return np.stack([r[:m] for r in rows])


# ---------------------------------------------------------------------------
# Calibration: f0s, schedule, per-harmonic measurement

def unique_harmonics(string_idx):
    """Harmonic numbers of this string that don't collide with the other
    strings' series (used for attribution; C4 has none vs C3, handled
    separately)."""
    if string_idx == 0:      # G3: collides with C-series at even k (k=2 -> C3 h3)
        return [k for k in range(1, N_HARM + 1) if k % 2 == 1]
    if string_idx == 3:      # C3: evens collide with C4, multiples of 3 with G3
        return [k for k in range(1, N_HARM + 1) if k % 2 == 1 and k % 3 != 0]
    # C4 strings: every harmonic is an even C3 harmonic. No unique set.
    return list(range(1, N_HARM + 1))


def refine_f0(x, nominal, sr=SR, span_cents=60, step_cents=2):
    """Maximize summed weighted harmonic-envelope energy over an f0 grid."""
    best_f, best_e = nominal, -1.0
    cents = np.arange(-span_cents, span_cents + step_cents, step_cents)
    # Use a representative 12 s slice for speed.
    slice_x = x[: int(min(len(x), 12 * sr))]
    for c in cents:
        f0 = nominal * 2 ** (c / 1200)
        e = 0.0
        for k in (1, 2, 3, 4, 5, 6, 8, 10):
            f = k * f0
            if f > 0.45 * sr:
                continue
            env = harmonic_envelope(slice_x, f, sr=sr, lp=0.1, hop=0.05)
            e += env.sum() / k
        if e > best_e:
            best_e, best_f = e, f0
    return best_f


def detect_plucks(x, f0s, sr=SR, min_dist=0.25, height_pct=92, min_rel=0.05):
    """Pluck schedule: ONSET TIMES from high-frequency spectral flux,
    ATTRIBUTION from fundamental-frequency jumps.

    Times: every pluck has a sharp broadband attack; HF flux localizes it
    to ±1 hop (~12 ms), far sharper than any smoothed-envelope novelty
    (the previous detector matched only 17/86 true attacks).

    Attribution: the fundamentals are the one place the strings don't
    collide — 131 Hz is unique to SA, 197 Hz unique to Pa. C4's
    fundamental (262 Hz) sits on SA's h2, so a sa pluck requires the
    262 jump to DOMINATE the 131 jump (a SA pluck raises both together;
    a sa pluck raises 262 alone). The two unison sa strings alternate
    model indices 1/2.
    """
    # --- onset times from HF spectral flux ---
    f, _, Z = signal.stft(x, sr, nperseg=2048, noverlap=2048 - 512)
    mag = np.abs(Z)
    hf = mag[(f > 1200) & (f < 9000)].sum(axis=0)
    flux = np.diff(np.maximum(hf, 0), prepend=hf[0])
    flux[flux < 0] = 0
    flux = signal.convolve(flux, np.ones(3) / 3, mode="same")
    fhop = 512 / sr
    # Height: percentile for dense playing, plus an absolute floor at a
    # fraction of the maximum so a mostly-silent sample (one pluck in 3 s)
    # doesn't pass its noise wiggles. min_dist must sit under the playing
    # style's IOI — the aux samples strum rolls at ~0.13 s.
    height = max(np.percentile(flux, height_pct), min_rel * flux.max())
    peaks, props = signal.find_peaks(flux, height=height,
                                     distance=max(2, int(min_dist / fhop)))
    onset_times = peaks * fhop
    flux_h = props["peak_heights"]

    # --- attribution from fundamental jumps ---
    env_pa = harmonic_envelope(x, f0s[0], sr=sr)   # 197 Hz, unique to Pa
    env_sa = harmonic_envelope(x, f0s[1], sr=sr)   # 262 Hz, C4 = SA's h2
    env_SA = harmonic_envelope(x, f0s[3], sr=sr)   # 131 Hz, unique to SA

    floor = {id(env_pa): np.percentile(env_pa, 10),
             id(env_sa): np.percentile(env_sa, 10),
             id(env_SA): np.percentile(env_SA, 10)}

    def jump_db(env, t0):
        i = int(t0 / ENV_HOP)
        pre = env[max(0, i - int(0.25 / ENV_HOP)):max(1, i - int(0.04 / ENV_HOP))]
        post = env[i + int(0.02 / ENV_HOP): i + int(0.30 / ENV_HOP)]
        if len(post) < 2:
            return 0.0, True
        # File-start edge: with no pre-baseline, fall back to the global
        # quiet floor so the opening plucks aren't silently dropped.
        had_pre = len(pre) >= 2
        base = np.median(pre) if had_pre else floor[id(env)]
        return float(20 * np.log10((np.percentile(post, 90) + 1e-7) /
                                   (base + 1e-7))), had_pre

    events = []
    for t0, fh in zip(onset_times, flux_h):
        j_pa, _ = jump_db(env_pa, t0)
        j_c4, had_pre = jump_db(env_sa, t0)
        j_SA, _ = jump_db(env_SA, t0)
        # C4 evidence discounted by C3-fundamental bleed: SA raises both
        # 131 and 262 (its h2); sa raises 262 alone. No evidence gate:
        # every sharp flux attack IS a pluck of one of the strings — a
        # re-pluck of an already-loud string shows only a small fundamental
        # jump, so gating on jump size throws away the most common case in
        # a dense drone. Argmax attribution always applies. From TRUE
        # silence (no pre-baseline) an SA pluck raises both fundamentals
        # by the full from-floor jump, so the discount must be full too.
        disc = 1.0 if not had_pre else 0.7
        scores = {0: j_pa, 3: j_SA, 1: j_c4 - disc * max(j_SA, 0.0)}
        sidx = max(scores, key=scores.get)
        events.append({"at": round(float(t0), 3), "string": sidx,
                       "jump": float(scores[sidx]), "flux": float(fh)})
    events.sort(key=lambda e: e["at"])

    # Alternate the two unison C4 strings.
    c4_flip = 0
    for e in events:
        if e["string"] == 1:
            e["string"] = 1 + (c4_flip % 2)
            c4_flip += 1

    # Velocity from attack-flux strength, normalized to [0.4, 1.0].
    fluxes = np.array([e["flux"] for e in events])
    ref90 = np.percentile(fluxes, 90) if len(fluxes) else 1.0
    for e in events:
        v = 0.4 + 0.6 * min(1.5, e["flux"] / max(ref90, 1e-9))
        e["velocity"] = round(min(1.0, v), 3)
        e.pop("jump", None)
        e.pop("flux", None)
    return events


def stacked_harmonics(x, events, f0s, sr=SR, n_harm=N_HARM, bed_subtract=False):
    """Pluck-synchronous per-harmonic measurement.

    The reference is played continuously, so truly isolated windows barely
    exist. Instead, for each string take EVERY one of its onsets, extract
    the per-harmonic envelopes for SEG_LEN after the onset (truncated at
    the string's own next pluck, padded with NaN), and take the nan-median
    across instances at each (harmonic, time) cell. Other strings' plucks
    land at varying offsets relative to this string's onsets, so the median
    rejects them; the string's own envelope is the consistent signal.

    bed_subtract: per instance, estimate each harmonic's pre-onset level
    (median over [-0.15, -0.03] s) and power-subtract it, so the matrix
    approximates the pluck's contribution ABOVE the already-ringing drone
    bed. This is the attribution fix: without it the sa (C4) matrices
    inherit SA's always-ringing even harmonics, and a loss fed by them
    rewards loud constant sa strings (the v4 failure). The operator is
    still applied identically to reference and candidate.

    Returns {string_idx: median A[k, t]} plus instance counts.
    """
    seg_frames = int(SEG_LEN / ENV_HOP)
    all_times = sorted(e["at"] for e in events)
    out = {}
    counts = {}
    for sidx in (0, 1, 3):
        own = [e["at"] for e in events
               if e["string"] == sidx or (sidx == 1 and e["string"] in (1, 2))]
        if len(own) < 3:
            continue
        own_sorted = sorted(own)
        stack = []
        # The whole-file envelope matrix once per string class (fast path:
        # one heterodyne per harmonic for the full file, then slice).
        full = measure_envelope_matrix(x, f0s[sidx], n_harm=n_harm, sr=sr)
        n_t = full.shape[1]
        for i, t0 in enumerate(own_sorted):
            i0 = int(t0 / ENV_HOP)
            # Truncate at the next event of ANY string: the playing cycle
            # is regular, so later plucks land at consistent offsets and a
            # median can NOT reject them — they must simply be excluded.
            nxt = [t for t in all_times if t > t0 + 0.05]
            t_stop = min(nxt[0] if nxt else t0 + SEG_LEN, t0 + SEG_LEN)
            usable = max(0.0, t_stop - t0 - 0.05)
            n_use = min(int(usable / ENV_HOP), seg_frames, n_t - i0)
            if n_use < int(0.3 / ENV_HOP):
                continue
            inst = np.full((n_harm, seg_frames), np.nan)
            inst[:, :n_use] = full[:, i0:i0 + n_use]
            if bed_subtract:
                b0 = i0 - int(0.15 / ENV_HOP)
                b1 = i0 - max(2, int(0.03 / ENV_HOP))
                if b0 >= 0 and b1 - b0 >= 3:
                    bed = np.median(full[:, b0:b1], axis=1)
                    with np.errstate(invalid="ignore"):
                        inst = np.sqrt(np.maximum(inst ** 2 - bed[:, None] ** 2, 0.0))
            stack.append(inst)
        if len(stack) < 3:
            continue
        arr = np.stack(stack)
        with np.errstate(all="ignore"):
            import warnings
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", RuntimeWarning)
                med = np.nan_to_num(np.nanmedian(arr, axis=0), nan=0.0)
        # Cells supported by too few instances are unreliable tails.
        support = np.sum(~np.isnan(arr), axis=0)
        med[support < 4] = 0.0
        # NOTE on bed_subtract=False: the raw operator is applied
        # IDENTICALLY to reference and candidates on the same schedule, so
        # the bed cancels for COMPARISON — but it does NOT cancel for
        # ALLOCATION between strings (sa's matrices inherit SA's even-
        # harmonic bed and vice versa). Use bed_subtract=True wherever the
        # matrices feed attribution (fit-init targets, the harm loss).
        if sidx == 1:
            out[1] = med
            out[2] = med
            counts[1] = counts[2] = len(stack)
        else:
            out[sidx] = med
            counts[sidx] = len(stack)
    return out, counts


def fit_harmonic_track(env, hop=ENV_HOP):
    """From one harmonic's envelope (one pluck): peak time, peak level,
    decay tau (log-linear fit after the peak), attack share."""
    if env.max() <= 1e-9:
        return None
    ipk = int(np.argmax(env))
    peak = float(env[ipk])
    # Peak time via the energy centroid of the region above 70% of max —
    # stable on broad/noisy envelopes where a raw argmax jumps between
    # near-equal local maxima.
    mask = env >= 0.7 * peak
    idx = np.arange(len(env))
    tp = float((idx[mask] * env[mask]).sum() / env[mask].sum() * hop)
    # Decay fit: from peak to where it falls 25 dB, ends, or hits a
    # zeroed (unsupported) cell.
    tail = env[ipk:]
    valid = tail > 0
    first_zero = int(np.argmin(valid)) if not valid.all() else len(tail)
    db = 20 * np.log10(np.maximum(tail, peak * 1e-4) / peak)
    end = np.argmax(db < -25) if (db < -25).any() else len(db)
    end = min(max(end, 8), len(db), max(first_zero, 4))
    if end < 4:
        return None
    tt = np.arange(end) * hop
    # least squares on dB: slope dB/s -> tau = -8.686 / slope
    A = np.vstack([tt, np.ones(end)]).T
    slope = np.linalg.lstsq(A, db[:end], rcond=None)[0][0]
    tau = -8.686 / min(slope, -1e-3)
    # A tau fit is only trustworthy if the window actually saw the
    # envelope drop; a truncated window that never decays ≥8 dB says
    # nothing about ring-out and must not feed decay trims.
    reliable = bool(-db[:end].min() >= 8.0)
    # Attack share: level shortly after onset relative to peak.
    i_att = min(len(env) - 1, int(0.06 / hop))
    att = float(env[i_att] / peak)
    return {"tp": float(tp), "peak": peak, "tau": float(np.clip(tau, 0.05, 20)),
            "attack": float(np.clip(att, 0, 1)), "reliable": reliable}


def cmd_decode_ref(args):
    os.makedirs(TDIR, exist_ok=True)
    src = args.mp3 or os.path.join(REPO, "tanpura.mp3")
    tmp = REF_WAV + ".tmp.wav"
    subprocess.run(["afconvert", "-f", "WAVE", "-d", f"LEI16@{SR}", "-c", "1",
                    src, tmp], check=True)
    os.replace(tmp, REF_WAV)
    print(REF_WAV)


def cmd_calibrate(args):
    x = load_wav_mono(REF_WAV)
    print(f"reference: {len(x)/SR:.1f}s")

    # Precise f0s (the two sa strings share one measurement).
    f_g = refine_f0(x, CANDIDATE_F0[0])
    f_c4 = refine_f0(x, CANDIDATE_F0[1])
    f_c3 = refine_f0(x, CANDIDATE_F0[3])
    f0s = [f_g, f_c4, f_c4, f_c3]
    for i, f in enumerate(f0s):
        cents = 1200 * np.log2(f / CANDIDATE_F0[i])
        print(f"  string {i} {STRING_NAMES[i]}: f0 = {f:.2f} Hz ({cents:+.1f}c vs 12-TET)")

    events = detect_plucks(x, f0s)
    print(f"  plucks detected: {len(events)}")
    iois = np.diff([e["at"] for e in events])
    if len(iois):
        print(f"  median IOI: {np.median(iois):.2f}s")
    counts = {s: sum(1 for e in events if e["string"] == s) for s in range(4)}
    print(f"  per-string counts: {counts}")

    mats, counts = stacked_harmonics(x, events, f0s)
    npz = {}
    summary = {}
    for sidx in sorted(mats.keys()):
        med = mats[sidx]
        npz[f"string{sidx}"] = med
        # Per-harmonic fits from the median matrix.
        fits = []
        for k in range(med.shape[0]):
            fit = fit_harmonic_track(med[k])
            fits.append(fit or {"tp": 0, "peak": 0, "tau": 1, "attack": 0})
        summary[str(sidx)] = {
            "f0": f0s[sidx],
            "instances": counts[sidx],
            "harmonics": fits,
        }
        # Human-readable bloom table for the first few harmonics.
        print(f"  {STRING_NAMES[sidx]} per-harmonic bloom (k: peak@s, tau s, rel dB):")
        pk0 = max(f["peak"] for f in fits) or 1
        for k in (1, 2, 3, 4, 5, 6, 8, 10, 12, 16):
            if k - 1 < len(fits) and fits[k - 1]["peak"] > 0:
                f = fits[k - 1]
                print(f"    h{k:2d}: tp={f['tp']:.2f}s tau={f['tau']:.2f}s "
                      f"{20*np.log10(f['peak']/pk0):+.1f}dB att={f['attack']:.2f}")

    model = {
        "sampleRate": SR,
        "f0s": f0s,
        "stringNames": STRING_NAMES,
        "events": events,
        "summary": summary,
        "envHop": ENV_HOP,
        "segLen": SEG_LEN,
        "nHarm": N_HARM,
    }
    os.makedirs(TDIR, exist_ok=True)
    atomic_write_json(REF_MODEL, model)
    tmp = REF_NPZ + ".tmp.npz"
    np.savez_compressed(tmp, **npz)
    os.replace(tmp, REF_NPZ)
    print(f"wrote {REF_MODEL}")
    print(f"wrote {REF_NPZ}")


def detect_tuning(x, sr=SR):
    """Tonic-agnostic 4-string tuning for an auxiliary sample.

    SA by harmonic-comb scan over 85–175 Hz (integer slots + the jawari
    half-integer slots, which are loud in real tanpuras), sa = 2·SA, and
    the 4th string from a small set of classical ratios (Pa 3/2, Ma 4/3,
    Ni 15/8, ni 7/4, low-ni 7/8 of SA). Returns (f0s[4], role)."""
    f, P = signal.welch(x, sr, nperseg=1 << 16)
    db = 10 * np.log10(P + 1e-15)

    def level(freq):
        return float(np.interp(freq, f, db))

    def floor_near(freq):
        m = (f > freq * 0.93) & (f < freq * 1.07)
        return float(np.median(db[m])) if m.any() else -150.0

    def comb_score(f0):
        s = 0.0
        for h, w in ((1, 1.0), (2, 1.0), (3, 0.9), (4, 0.7), (5, 0.5),
                     (6, 0.4), (1.5, 0.4), (2.5, 0.3), (3.5, 0.3)):
            fq = h * f0
            if fq > 6000:
                break
            s += w * max(0.0, level(fq) - floor_near(fq))
        return s

    grid = np.geomspace(85, 175, 240)
    SA = float(grid[int(np.argmax([comb_score(g) for g in grid]))])
    # Fifth/octave disambiguation: a strong h4.5 half-integer of the TRUE
    # SA lands exactly on h3 of 1.5·SA, so the comb can crown Pa instead
    # (it did, on two samples). If a fifth or octave down scores
    # comparably, the lower fundamental is the tonic.
    for div, thresh in ((1.5, 0.80), (2.0, 0.75)):
        lower = SA / div
        if lower >= 60 and comb_score(lower) >= thresh * comb_score(SA):
            SA = lower
    SA = refine_f0(x, SA, span_cents=60)
    sa = refine_f0(x, 2 * SA, span_cents=40)

    cands = {"Pa": 1.5, "Ma": 4.0 / 3.0, "Ni": 15.0 / 8.0,
             "ni": 7.0 / 4.0, "low-ni": 7.0 / 8.0}
    best = None
    for role, r in cands.items():
        fx = refine_f0(x, r * SA, span_cents=45)
        sc = max(0.0, level(fx) - floor_near(fx)) \
            + 0.5 * max(0.0, level(2 * fx) - floor_near(2 * fx))
        ratio = fx / SA
        if abs(ratio - round(ratio)) < 0.02 * max(1, round(ratio)):
            sc *= 0.3  # collides with SA's own series — weak evidence
        if best is None or sc > best[0]:
            best = (sc, role, fx)
    _, role, fX = best
    return [float(fX), float(sa), float(sa), float(SA)], role


def pluck_smoothness(x, events, sr=SR, min_gap=1.8, hop=0.04, band=None):
    """Per isolated pluck (gap to next event ≥ min_gap): RMS deviation
    (dB) of the envelope from a straight-line decay over
    [t0+0.25, t0+min(gap, 4)], optionally bandpassed (the jiva pump
    concentrates mid-band).

    This is the 'wah-wah' metric: independent per-harmonic undulation
    that PUMPS the summed envelope scores high; energy redistribution
    BETWEEN harmonics (the real tanpura behavior — total decays smoothly
    while the spectrum shifts) scores low. Applied identically to
    reference and candidate; paired by event index. Measured reference
    range 0.3–2.1 dB; the v6 model scored 1.5–2.2 wideband."""
    times = sorted(e["at"] for e in events)
    dur = len(x) / sr
    sos = signal.butter(4, band, btype="band", fs=sr, output="sos") \
        if band is not None else None
    out = []
    for i, t0 in enumerate(times):
        nxt = times[i + 1] if i + 1 < len(times) else dur
        gap = min(nxt - t0, dur - t0)
        if gap < min_gap:
            out.append(None)
            continue
        seg = x[int((t0 + 0.25) * sr):int((t0 + min(gap, 4.0) - 0.05) * sr)]
        if len(seg) < sr:
            out.append(None)
            continue
        if sos is not None:
            seg = signal.sosfilt(sos, seg)
        env = wideband_env_db(seg, hop=hop, win=2 * hop)
        tt = np.arange(len(env)) * hop
        A = np.vstack([tt, np.ones(len(env))]).T
        coef, *_ = np.linalg.lstsq(A, env, rcond=None)
        out.append(float((env - A @ coef).std()))
    return out


# Envelope-modulation rate bands (Hz) and the reference's isolated-pluck
# target profile, measured from tanpura1/tanpura2 (single-pluck samples):
# a TIGHT peak at 1.5–2.5 Hz that falls off sharply above. The model's
# independent random-rate jiva instead smears 1.5–7 Hz — the audible
# "wah-wah". modspec penalizes pump energy ABOVE the reference's level in
# the fast bands (one-sided: matching the 2 Hz peak is free, exceeding the
# reference's fast pump is not).
MODSPEC_BANDS = [(1.5, 2.5), (2.5, 4.0), (4.0, 7.0)]
MODSPEC_TARGET = {(2.5, 4.0): 0.052, (4.0, 7.0): 0.021}  # mid-band, ref


def env_mod_profile(x, t0, sr=SR, dur=2.5, band=(500.0, 3000.0)):
    """Pump depth (fraction of envelope mean) per MODSPEC band of one
    isolated pluck's post-attack envelope, cubic-detrended so the smooth
    bloom/decay doesn't count — only periodic pumping does."""
    seg = x[int((t0 + 0.3) * sr):int((t0 + 0.3 + dur) * sr)]
    if len(seg) < sr:
        return None
    if band is not None:
        sos = signal.butter(4, band, btype="band", fs=sr, output="sos")
        seg = signal.sosfilt(sos, seg)
    env = np.abs(signal.hilbert(seg))
    env = signal.decimate(signal.decimate(env, 10, ftype="fir"), 10, ftype="fir")
    sr_e = sr / 100.0
    tt = np.arange(len(env))
    resid = env - np.polyval(np.polyfit(tt, env, 3), tt)
    f, P = signal.welch(resid, sr_e, nperseg=min(256, len(resid)))
    mn = env.mean() + 1e-9
    return {b: float(np.sqrt(P[(f >= b[0]) & (f < b[1])].sum()) / mn)
            for b in MODSPEC_BANDS}


def modspec_loss(iso_path):
    """One-sided excess fast-pump on the isolated-pluck render vs the
    reference's measured falloff (the wah-wah signature the smooth/
    isosmooth terms can't see — they measure total deviation, not its
    RATE). Per pluck, sum the excess over rate bands; return the WORST
    pluck, not the mean — averaging let the optimizer fix the loud SA/sa
    drones while sacrificing Pa (run 13). The worst-string rule forbids
    that: every string must be clean."""
    x = load_wav_mono(iso_path)
    worst = 0.0
    for t0, _s in ISO_PLUCKS:
        prof = env_mod_profile(x, t0)
        if prof is None:
            continue
        e = sum(max(0.0, prof[b] - target) * 10.0
                for b, target in MODSPEC_TARGET.items())
        worst = max(worst, e)
    return worst


def cmd_calibrate_aux(args):
    """Calibrate ONE auxiliary reference sample (any tonic, any 4th-string
    role) into auditions/tanpura/refs/<name>/: tuning detection → pluck
    schedule → model.json + a schedule-overlay PNG for eyeballing. Aux
    refs feed specres/tune/attack/pulse/smooth (no harm matrices — most
    are too short for pluck-synchronous stacking)."""
    name = args.name or os.path.splitext(os.path.basename(args.input))[0]
    d = os.path.join(TDIR, "refs", name)
    os.makedirs(d, exist_ok=True)
    wav_out = os.path.join(d, "reference.wav")
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@44100", "-c", "1",
                    args.input, wav_out], check=True, capture_output=True)
    x = load_wav_mono(wav_out)
    f0s, role = detect_tuning(x)
    events = detect_plucks(x, f0s, min_dist=0.1, height_pct=75)
    # Sparse samples: a mostly-silent file's flux percentile sits in the
    # noise, letting wiggles through (a 3 s single-pluck sample grew 3
    # phantom events — which themselves inflate the density check, hence
    # the generous threshold). When playing is sparse, re-detect with the
    # percentile up in the attack-region range.
    if len(events) / (len(x) / SR) < 1.6:
        events = detect_plucks(x, f0s, min_dist=0.1, height_pct=97, min_rel=0.15)
    counts = {s: sum(1 for e in events if e["string"] == s) for s in range(4)}
    sm = [v for v in pluck_smoothness(x, events) if v is not None]
    model = {"sampleRate": SR, "f0s": f0s, "role4": role, "events": events,
             "duration": round(len(x) / SR, 3), "name": name}
    atomic_write_json(os.path.join(d, "model.json"), model)
    # Overlay: events ticked at their string's fundamental row.
    img = logspec_image(x).copy()
    h, w_, _ = img.shape
    rows = np.geomspace(55, 8000, h)
    dur = len(x) / SR
    colors = [(255, 80, 80), (80, 255, 80), (80, 200, 255), (255, 255, 80)]
    for e in events:
        col = min(w_ - 1, int(e["at"] / dur * w_))
        ridx = h - 1 - int(np.searchsorted(rows, f0s[e["string"]]))
        for dr in range(-4, 5):
            r = min(max(ridx + dr, 0), h - 1)
            img[r, col] = colors[e["string"]]
    write_png(os.path.join(d, "overlay.png"), img)
    print(f"{name}: {len(x)/SR:.2f}s  SA={f0s[3]:.2f} sa={f0s[1]:.2f} "
          f"X={f0s[0]:.2f} ({role})  events={len(events)} {counts}  "
          f"isolated-pluck smoothness: {[round(v,2) for v in sm] or 'none'}")
    print(os.path.join(d, "model.json"))


def cmd_rematrix(args):
    """Recompute the per-string harmonic matrices + summaries from the
    EXISTING schedule (events/f0s in reference_model.json are preserved
    untouched — run schedule-check first if in doubt), with bed
    subtraction and a deeper measured harmonic count. The previous
    NPZ/model are backed up once as *_prebed.* so the raw-operator
    matrices remain available for comparison."""
    model = json.load(open(REF_MODEL))
    x = load_wav_mono(REF_WAV)
    mats, counts = stacked_harmonics(x, model["events"], model["f0s"],
                                     n_harm=args.n_harm, bed_subtract=True)
    npz = {}
    summary = {}
    for sidx in sorted(mats.keys()):
        med = mats[sidx]
        npz[f"string{sidx}"] = med
        fits = []
        for k in range(med.shape[0]):
            fit = fit_harmonic_track(med[k])
            fits.append(fit or {"tp": 0, "peak": 0, "tau": 1, "attack": 0,
                                "reliable": False})
        summary[str(sidx)] = {
            "f0": model["f0s"][sidx],
            "instances": counts[sidx],
            "harmonics": fits,
        }
        pk0 = max(f["peak"] for f in fits) or 1
        print(f"  {STRING_NAMES[sidx]} bed-subtracted bloom (k: peak@s, tau s, rel dB):")
        for k in (1, 2, 3, 4, 6, 8, 12, 16, 24, 32):
            if k - 1 < len(fits) and fits[k - 1]["peak"] > 0:
                f = fits[k - 1]
                print(f"    h{k:2d}: tp={f['tp']:.2f}s tau={f['tau']:.2f}s "
                      f"{20*np.log10(f['peak']/pk0):+.1f}dB att={f['attack']:.2f}")
    for src, bak in ((REF_NPZ, REF_NPZ[:-4] + "_prebed.npz"),
                     (REF_MODEL, REF_MODEL[:-5] + "_prebed.json")):
        if os.path.exists(src) and not os.path.exists(bak):
            shutil.copyfile(src, bak)
    model["summary"] = summary
    model["nHarm"] = args.n_harm
    model["bedSubtract"] = True
    atomic_write_json(REF_MODEL, model)
    tmp = REF_NPZ + ".tmp.npz"
    np.savez_compressed(tmp, **npz)
    os.replace(tmp, REF_NPZ)
    print(f"wrote {REF_MODEL}")
    print(f"wrote {REF_NPZ}")


# ---------------------------------------------------------------------------
# fit-init: measured TanpuraParams

def fit_loglaw(ks, vals):
    """Fit vals ≈ A * k^B in log domain; returns (A, B, residual array)."""
    ks = np.asarray(ks, dtype=float)
    v = np.asarray(vals, dtype=float)
    ok = v > 0
    if ok.sum() < 3:
        return 1.0, 0.0, np.zeros(len(ks))
    lk, lv = np.log(ks[ok]), np.log(v[ok])
    M = np.vstack([np.ones(ok.sum()), lk]).T
    (lA, B), *_ = np.linalg.lstsq(M, lv, rcond=None)
    resid = np.zeros(len(ks))
    resid[ok] = lv - (lA + B * lk)
    return float(np.exp(lA)), float(B), resid


def cmd_fit_init(args):
    model = json.load(open(REF_MODEL))
    # Hybrid measurement use: GAINS (peaks → falloff/pluckPos/gainTrimDB/
    # levels) come from the current summary — bed-subtracted after
    # `rematrix`, which is the attribution fix. TIME laws (decay, bloom)
    # come from the RAW (_prebed) summary when present: subtracting a
    # CONSTANT bed over-subtracts the tail (the bed itself decays), which
    # collapses every bed-subtracted tau to the 0.05 s floor — useless for
    # initializing decay.
    prebed = None
    prebed_path = REF_MODEL[:-5] + "_prebed.json"
    if model.get("bedSubtract") and os.path.exists(prebed_path):
        prebed = json.load(open(prebed_path))
    # Synthesize the full harmonic stack: trims beyond the measured count
    # stay neutral and follow the fitted laws (the engine skips partials
    # above 0.45·fs). The measured HF sheen lives at 3–8 kHz, far above
    # the old 24-harmonic cap.
    params = {"harmonicCount": 64, "strings": []}
    levels = []
    for sidx in range(4):
        s = model["summary"].get(str(sidx))
        if s is None:
            s = model["summary"][str(1)]  # sa pair shares measurement
        fits = s["harmonics"]
        n_k = len(fits)
        ks = np.arange(1, n_k + 1)
        peaks = np.array([f["peak"] for f in fits])
        tfits = fits
        meas = np.ones(n_k, dtype=bool)  # harmonics with REAL time data
        if prebed is not None:
            t = prebed["summary"].get(str(sidx)) or prebed["summary"][str(1)]
            # Pad the (shorter) raw measurement with placeholders, and mask
            # them OUT of every time-law fit: padded tp=0.01/attack=0
            # values would otherwise drag the bloom law and attack share
            # toward garbage for k>measured (review finding).
            n_meas = min(len(t["harmonics"]), n_k)
            meas = np.zeros(n_k, dtype=bool)
            meas[:n_meas] = True
            tfits = t["harmonics"] + [{"tp": 0.01, "tau": 1, "attack": 0,
                                       "peak": 0, "reliable": False}] \
                * max(0, n_k - len(t["harmonics"]))
            tfits = tfits[:n_k]
        taus = np.array([f["tau"] for f in tfits])
        tps = np.array([max(0.01, f["tp"]) for f in tfits])
        atts = np.array([f["attack"] for f in tfits])
        good = peaks > peaks.max() * 10 ** (-50 / 20)

        # Gain law: grid pluckPos, fit falloff on comb-corrected gains.
        best = None
        for pp in np.arange(0.04, 0.42, 0.02):
            comb = np.maximum(0.05, np.abs(np.sin(np.pi * ks * pp)))
            A, B, resid = fit_loglaw(ks[good], (peaks / comb)[good])
            err = float(np.abs(resid).sum())
            if best is None or err < best[0]:
                best = (err, pp, A, B)
        _, pluck_pos, gainA, gainB = best
        falloff = float(np.clip(-gainB, 0, 4))
        comb = np.maximum(0.05, np.abs(np.sin(np.pi * ks * pluck_pos)))
        law_gain = comb * ks ** (-falloff)
        trim_db = np.zeros(n_k)
        trim_db[good] = 20 * np.log10(np.maximum(peaks[good], 1e-9) /
                                      np.maximum(law_gain[good] * gainA, 1e-9))
        trim_db = np.clip(trim_db - np.median(trim_db[good]) if good.any() else trim_db,
                          -40, 18)
        trim_db[~good] = -30.0

        # Decay law + trims — fit ONLY on harmonics whose decay fit was
        # reliable (the measurement window actually saw ≥8 dB of drop);
        # truncated windows say nothing about ring-out and previously
        # injected absurd 8× trims here. Trims clipped to a sane band;
        # the optimizer's temporal metrics own the rest.
        reliable = np.array([bool(f.get("reliable")) for f in tfits])
        fit_ok = good & reliable
        if fit_ok.sum() >= 3:
            decayA, decayB, _ = fit_loglaw(ks[fit_ok], taus[fit_ok])
        else:
            decayA, decayB = 4.0, -0.6
        damp_tilt = float(np.clip(-decayB, 0, 2))
        decay = float(np.clip(decayA, 0.2, 8))
        law_tau = decay * ks ** (-damp_tilt)
        decay_trim = np.clip(taus / np.maximum(law_tau, 1e-3), 0.3, 3)
        decay_trim[~fit_ok] = 1.0

        # Peak-time law + trims (time data only where actually measured).
        good_t = good & meas
        bloomA, bloomB, _ = fit_loglaw(ks[good_t], tps[good_t])
        bloom_skew = float(np.clip(bloomB, 0, 2))
        bloom_delay = float(np.clip(bloomA, 0.0, 0.7))
        law_tp = max(bloom_delay, 1e-3) * ks ** bloom_skew
        peak_trim = np.clip(tps / np.maximum(law_tp, 1e-3), 0.3, 3)
        peak_trim[~good_t] = 1.0

        attack_level = float(np.clip(np.median(atts[good_t]) if good_t.any() else 0.4, 0, 1))
        level = float(np.sqrt((peaks[good] ** 2).sum())) if good.any() else 0.5
        levels.append(level)

        params["strings"].append({
            "f0": s["f0"] if sidx != 2 else model["summary"][str(1)]["f0"],
            "level": level,  # normalized below
            "falloff": falloff,
            "pluckPos": float(pluck_pos),
            "decay": decay,
            "dampTilt": damp_tilt,
            "bloomDelay": bloom_delay,
            "bloomSkew": bloom_skew,
            "attackLevel": attack_level,
            "attackDecay": 0.04,
            "inharmonicity": 0.00002 if sidx != 3 else 0.00008,
            "gainTrimDB": [round(float(v), 2) for v in trim_db],
            "peakTrim": [round(float(v), 3) for v in peak_trim],
            "decayTrim": [round(float(v), 3) for v in decay_trim],
        })
    # String f0s: use each string's own measurement.
    for sidx in range(4):
        params["strings"][sidx]["f0"] = model["f0s"][sidx]
    # Normalize levels to ≤ 1.2.
    top = max(levels) or 1
    for s, lv in zip(params["strings"], levels):
        s["level"] = round(min(1.2, lv / top), 3)

    out = args.out or os.path.join(TDIR, "measured_init.json")
    atomic_write_json(out, params)
    print(out)


# ---------------------------------------------------------------------------
# Loss

DEFAULT_WEIGHTS = {
    # THE acceptance-bar metric (run 6+): per-cell |ΔdB| between the
    # reference's and candidate's ABSOLUTE log-frequency spectrograms on
    # the aligned schedule, audibility-weighted, 90 Hz–16 kHz. This is
    # "the spectrograms should look identical" made differentiable: it
    # sees band means (ltas), band trajectories (spec), the wideband
    # envelope (env) — and, unlike all of them, WHICH string's energy
    # fills a shared band at each moment, because the schedules force
    # when each band is re-fed. Reported in dB (v4 scored ~14.5; the
    # two-seed stochastic floor is ~3.5).
    "specres": 3.0,
    # Per-harmonic bloom shape over the densely-supported first 1.2 s,
    # now on BED-SUBTRACTED matrices (attribution-corrected) both sides.
    # Low weight: the bed-subtracted operator has a large noise floor
    # (~44 of v4's ~45 score is floor, only ~4% separated v4 from the
    # corrected init), so it shapes rather than drives.
    "harm": 0.3,
    # Paired inter-onset envelope drops — pluck-shaped vs smeared.
    "pulse": 1.0,
    # Single-pluck ring-time bracket on an isolated-pluck render —
    # texture statistics CANNOT see individual ring-out in a dense drone;
    # this is the term that forbids near-infinite string decay. Weighted
    # as a constraint: zero inside the bracket, decisively expensive out.
    "ring": 6.0,
    # Saturation guard: fraction of candidate samples inside the output
    # limiter's knee (|x| > 0.84). Every level-sensitive metric RMS-
    # normalizes, so absolute gain is otherwise invisible — run 2 exploited
    # that by driving 60% of samples into the limiter (crest 1.7 dB vs the
    # reference's 13.6 dB). Weighted as a WALL (at 50, run 4 still traded
    # ~3% saturation for 1.5 loss points). Zero for any clean render.
    "clip": 300.0,
    # Within-band partial tuning: mean cents from reference spectral peaks
    # to the candidate's nearest real peak (/8). The ~80-cent specres bands
    # cannot see sourness; the detune/inharmonicity dims can create it.
    "tune": 1.0,
    # Paired per-onset 2–8 kHz transient (rise dB /4 + |Δlog rise-time|):
    # the chik and bloom snap live below specres' 70 ms smear.
    "attack": 0.75,
    # Sub-70ms texture depth (jiva pulsing) that specres' time smear hides.
    "mod": 0.5,
    # Paired isolated-pluck envelope smoothness (wideband + mid-band) —
    # the wah-wah guard. Independent per-harmonic LFOs that pump the SUM
    # score high; real tanpura jiva redistributes energy between
    # harmonics while the total decays smoothly. Carried by the sparse
    # aux references (the dense main reference has no isolated plucks).
    "smooth": 2.0,
    # Absolute isolated-pluck smoothness above a 1.2 dB allowance, on the
    # iso render at the model's own tuning (the paired term can be quiet
    # at aux tunings while the wah-wah persists at ours).
    "isosmooth": 2.0,
    # Envelope-modulation RATE on the iso render: one-sided penalty for
    # fast-pump (2.5–7 Hz) energy beyond the reference's tight ~2 Hz
    # falloff, on the WORST string (not the mean — averaging let run 13
    # fix SA/sa while wrecking Pa). THE wah-wah term — smooth/isosmooth
    # see total envelope deviation but not whether it's a smooth bloom or
    # a periodic pump.
    "modspec": 5.0,
    # Subsumed by specres (kept at 0 so loss_weights.json can revive them
    # for diagnostics; zero-weight components are skipped entirely):
    "spec": 0.0,
    "ltas": 0.0,
    "env": 0.0,
}

# Cache of the decoded reference and its derived measurements (the
# optimizer calls compute_loss thousands of times from long-lived workers).
_REF_CACHE = {}


# --- Temporal measurements -------------------------------------------------

def gap_decay_slopes(x, events, f0s, min_gap=1.2, max_inst=4, n_harm=16):
    """Per string: gain-weighted per-harmonic decay slopes (dB/s) measured
    on the LONGEST inter-event gaps after the string's own plucks — the
    only places where ring-out is actually observable in a continuous
    drone. Applied identically to reference and candidate (same schedule),
    so a candidate that keeps ringing where the reference decays shows a
    near-zero slope against the reference's strongly negative one.

    Returns {sidx: (slopes[n_harm], weights[n_harm])}.
    """
    all_times = sorted(e["at"] for e in events)
    dur = len(x) / SR
    out = {}
    for sidx in (0, 1, 3):
        own = sorted(e["at"] for e in events
                     if e["string"] == sidx or (sidx == 1 and e["string"] in (1, 2)))
        insts = []
        for t0 in own:
            nxt = [t for t in all_times if t > t0 + 0.05]
            gap = (nxt[0] if nxt else min(t0 + SEG_LEN, dur)) - t0
            if t0 + gap > dur:
                gap = dur - t0
            if gap >= min_gap:
                insts.append((gap, t0))
        insts.sort(reverse=True)
        insts = insts[:max_inst]
        if not insts:
            continue
        slopes = np.zeros(n_harm)
        weights = np.zeros(n_harm)
        for gap, t0 in insts:
            i0 = int(t0 * SR)
            i1 = int((t0 + gap - 0.05) * SR)
            seg = x[i0:i1]
            for k in range(1, n_harm + 1):
                f = k * f0s[sidx]
                if f > 0.45 * SR:
                    continue
                env = harmonic_envelope(seg, f)
                j0 = int(0.25 / ENV_HOP)
                e = env[j0:]
                if len(e) < 20 or env.max() < 1e-6:
                    continue
                db = 20 * np.log10(np.maximum(e, env.max() * 1e-4))
                tt = np.arange(len(db)) * ENV_HOP
                A = np.vstack([tt, np.ones(len(db))]).T
                sl = np.linalg.lstsq(A, db, rcond=None)[0][0]
                w = env.max()
                slopes[k - 1] += sl * w
                weights[k - 1] += w
        ok = weights > 0
        slopes[ok] /= weights[ok]
        out[sidx] = (slopes, weights)
    return out


# Pluck times of the isolated-pluck render used by the ring-time loss:
# one pluck per string (string 2 shares string 1's measurement), far
# enough apart that each decay is fully observable.
ISO_PLUCKS = [(0.2, 0), (6.2, 1), (12.2, 3)]
ISO_DURATION = 18.5


# Single-pluck ring-time brackets (seconds to fall 20 dB below peak),
# derived from the reference's observed inter-onset decay rates (gaps fall
# 3–6 dB/s after the attack → T20 ≈ 3.3–6.7 s wideband) and the physical
# behavior of upper tanpura harmonics (faster). Generous on purpose: the
# bracket forbids organ-like infinite ring (and over-choked thuds) while
# the texture metrics shape everything inside it.
RING_BRACKETS = [
    (None, 2.0, 6.5),            # wideband
    ((800.0, 3200.0), 0.6, 4.0), # upper harmonics
    ((3200.0, 8000.0), 0.2, 2.5),  # sheen — fast by physics; reachable since
                                   # the 64-harmonic cap, so it needs its own
                                   # anti-smear bracket
]


def ring_loss(iso_path, ref_model=None):
    """Single-pluck ring-time bracket — the anti-smear constraint.

    The reference never isolates a pluck, so its texture statistics cannot
    pin individual ring-out (a 100 s decay and a 4 s decay look alike when
    the next pluck always re-feeds the band; this is exactly how the first
    optimization run produced an organ). This term measures OUR isolated
    render — clean by construction — estimating each pluck's T20 from the
    envelope slope after the peak (slope-based, so a never-decaying pluck
    extrapolates to a huge T20 instead of saturating at the window edge)
    and penalizing log-distance outside the bracket.
    """
    x = load_wav_mono(iso_path)
    hop = 0.025
    total = 0.0
    n = 0
    for t0, _sidx in ISO_PLUCKS:
        seg = x[int(t0 * SR):min(len(x), int((t0 + 5.8) * SR))]
        for band, lo, hi in RING_BRACKETS:
            y = seg
            if band is not None:
                sos = signal.butter(4, band, btype="band", fs=SR, output="sos")
                y = signal.sosfilt(sos, seg)
            env = wideband_env_db(y)
            if len(env) < 30:
                continue
            pk = int(np.argmax(env))
            tail = env[pk + int(0.3 / hop):]
            if len(tail) < 20:
                continue
            tt = np.arange(len(tail)) * hop
            A = np.vstack([tt, np.ones(len(tail))]).T
            slope = np.linalg.lstsq(A, tail, rcond=None)[0][0]  # dB/s
            if slope >= -0.1:
                t20 = 60.0  # still blooming or flat at window end
            else:
                t20 = 20.0 / -slope
            if t20 < lo:
                total += float(np.log(lo / t20))
            elif t20 > hi:
                total += float(np.log(t20 / hi))
            n += 1
    return total / max(n, 1)


def abs_logspec_bands(x, bands=112, fmin=90, fmax=16000):
    """ABSOLUTE log-frequency band spectrogram in dB (~70 ms time smear).
    Band means are kept: this is the grid behind the acceptance-bar
    residual, where absolute per-band levels are exactly the point.
    fmin=90 excludes the recording's sub-90 Hz rumble, which is NOT
    pluck-locked (measured +0.7 dB mean onset rise — room/handling noise,
    -28 dBpk) and which the string model intentionally does not make.
    fmax=16000 covers the reference's full bandwidth (mp3 content to
    ~16 kHz, -47…-65 dBpk above 8 k): with the 64-harmonic engine the
    8–16 kHz octave is REACHABLE, and leaving it off the grid would make
    it a loss-free zone (review finding — the run-1..4 exploit class).
    Bands whose geomspace width falls below one FFT bin (~10.8 Hz, i.e.
    below ~225 Hz) borrow the nearest bin so no band is structurally
    empty."""
    f, _, Z = signal.stft(x, SR, nperseg=4096, noverlap=4096 - 1024)
    P = (np.abs(Z) ** 2)
    edges = np.geomspace(fmin, fmax, bands + 1)
    centers = np.sqrt(edges[:-1] * edges[1:])
    M = np.zeros((bands, P.shape[1]))
    for i in range(bands):
        m = (f >= edges[i]) & (f < edges[i + 1])
        if m.any():
            M[i] = P[m].mean(axis=0)
        else:
            M[i] = P[np.argmin(np.abs(f - centers[i]))]
    if M.shape[1] >= 3:  # 3-frame box ≈ 70 ms at hop 1024
        M = np.concatenate([M[:, :1], M, M[:, -1:]], axis=1)
        M = (M[:, :-2] + M[:, 1:-1] + M[:, 2:]) / 3
    return 10 * np.log10(M + 1e-13)


def logspec_bands(x, bands=96, fmin=70, fmax=8000):
    """Mean-removed variant: each band's trajectory relative to its own
    window average — the temporal pattern only ("smeared vs pluck-shaped").
    Superseded as a loss term by the absolute-grid specres, kept for
    diagnostics and refine-schedule."""
    db = abs_logspec_bands(x, bands=bands, fmin=fmin, fmax=fmax)
    return db - db.mean(axis=1, keepdims=True)


# Audibility floor for the specres weighting, dB below the reference
# window's peak cell. Cells where BOTH sides sit below the floor are
# ignored; weight ramps linearly up to the peak, so loud cells dominate
# the score the way they dominate a spectrogram (and a listener).
SPECRES_FLOOR_DB = 65.0


def _hp90(x):
    """Restrict to the grid's 90 Hz–16 kHz view for RMS matching: a highpass
    alone would let out-of-band energy deflate every visible band of the
    normalized grid — a free global gain knob for the optimizer."""
    sos = signal.butter(4, [90.0, 16000.0], btype="band", fs=SR, output="sos")
    return signal.sosfilt(sos, x)


def specres_grids(r, c):
    """Loudness-matched absolute spectrogram grids + per-cell weights.

    Both segments are RMS-normalized on their in-grid (90 Hz–16 kHz)
    content (the reference's rumble must not shift its visible-band
    levels). The weight uses max(ref, cand) against the REFERENCE's peak:
    candidate energy that is loud where the reference is quiet raises its
    own weight — it cannot hide — while cells quiet on both sides don't
    count.
    """
    rn = r / (np.sqrt((_hp90(r) ** 2).mean()) + 1e-12)
    cn = c / (np.sqrt((_hp90(c) ** 2).mean()) + 1e-12)
    A = abs_logspec_bands(rn)
    B = abs_logspec_bands(cn)
    tt = min(A.shape[1], B.shape[1])
    A, B = A[:, :tt], B[:, :tt]
    pk = A.max()
    w = np.clip((np.maximum(A, B) - (pk - SPECRES_FLOOR_DB)) / SPECRES_FLOOR_DB,
                0.0, 1.0)
    return A, B, w


# Box length (s) separating the schedule-locked mean structure from the
# stochastic fast component in the specres split below.
SPECRES_SLOW_S = 0.7


def specres_eval(A, B, w, hop=1024.0 / SR):
    """Two-part residual: {slow, std, total}.

    slow — weighted per-cell |ΔdB| on ~0.7 s-smoothed grids: the
    schedule-locked mean structure (where energy sits, when bands are
    re-fed and decay).

    std — per-band |Δ| of the temporal std of the FAST component: the
    modulation depth (jiva, beating, pluck jitter). Scored as a statistic,
    NOT per-cell, because per-cell residual on stochastic texture rewards
    flattening: a candidate that modulates honestly but with independent
    phase scores ~1.13σ per cell while a dead-flat one scores ~0.80σ —
    regression to the mean (review finding). Matching the depth statistic
    is seed-proof; killing the modulation is not.
    """
    from scipy.ndimage import uniform_filter1d
    n = max(3, int(round(SPECRES_SLOW_S / hop)))
    As = uniform_filter1d(A, n, axis=1, mode="nearest")
    Bs = uniform_filter1d(B, n, axis=1, mode="nearest")
    slow = float((w * np.abs(As - Bs)).sum() / (w.sum() + 1e-12))
    sr_ = (A - As).std(axis=1)
    sc_ = (B - Bs).std(axis=1)
    wb = w.mean(axis=1)
    std = float((wb * np.abs(sr_ - sc_)).sum() / (wb.sum() + 1e-12))
    return {"slow": slow, "std": std, "total": slow + std}


def specres_score(A, B, w):
    return specres_eval(A, B, w)["total"]


def _top_peaks(x, fmin, fmax, n):
    """Frequencies of the n strongest local spectral maxima in [fmin,fmax],
    de-clustered to >40 cents apart (one entry per partial, not per lobe
    bin)."""
    f, P = signal.welch(x, SR, nperseg=1 << 16)
    db = 10 * np.log10(P + 1e-15)
    sel = np.where((f >= fmin) & (f <= fmax))[0]
    loc = sel[(db[sel] > np.roll(db, 1)[sel]) & (db[sel] >= np.roll(db, -1)[sel])]
    loc = loc[np.argsort(db[loc])[::-1]]
    kept = []
    for i in loc:
        lf = np.log2(f[i])
        if all(abs(1200 * (lf - k)) > 40 for k in kept):
            kept.append(lf)
        if len(kept) >= n:
            break
    return np.array(kept)  # log2(freq)


def tune_error(r, c, fmin=300.0, fmax=8000.0, n_peaks=40):
    """Mean |cents| from the reference's strongest partials to the
    candidate's nearest top partial within ±60 cents. Guards the
    within-band sourness the ~80-cent specres bands cannot see
    (saDetuneCents and inharmonicity can park partials tens of cents off
    with zero specres cost — review finding). Both sides go through the
    SAME top-peak extraction (self-test is exactly 0); ref peaks with no
    candidate partial nearby are skipped — missing energy is specres'
    job, not tune's."""
    ref_pk = _top_peaks(r, fmin, fmax, n_peaks)
    cand_pk = _top_peaks(c, fmin, fmax, 3 * n_peaks)
    if not len(ref_pk) or not len(cand_pk):
        return 0.0
    errs = []
    for lf in ref_pk:
        cents = 1200 * np.abs(cand_pk - lf)
        e = cents.min()
        if e <= 60.0:
            errs.append(e)
    return float(np.mean(errs)) if errs else 0.0


def attack_stats(x, events, t0, t1):
    """Per scheduled onset in [t0,t1): (rise dB, rise-time ms) of the
    2–8 kHz envelope at 5 ms resolution over [-25,+90] ms around the
    onset. The pluck 'chik' and bloom snap live entirely below specres'
    70 ms smear (review finding). Paired ref/candidate by event index."""
    sos = signal.butter(4, [2000.0, 8000.0], btype="band", fs=SR, output="sos")
    seg = signal.sosfilt(sos, x[int(t0 * SR):int(t1 * SR)])
    env = wideband_env_db(seg, hop=0.005, win=0.010)
    hop = 0.005
    out = []
    for e in events:
        te = e["at"] - t0
        if te < 0.05 or te > (t1 - t0) - 0.15:
            out.append(None)
            continue
        i = int(te / hop)
        pre = env[max(0, i - 5):max(1, i - 1)].mean()
        post = env[i:i + 18]
        if len(post) < 6:
            out.append(None)
            continue
        pk = float(post.max())
        rise_db = pk - pre
        # 10–90% (in dB) rise time
        th10, th90 = pre + 0.1 * rise_db, pre + 0.9 * rise_db
        above10 = np.where(post >= th10)[0]
        above90 = np.where(post >= th90)[0]
        rise_ms = ((above90[0] - above10[0]) * hop * 1000.0
                   if len(above10) and len(above90) else 90.0)
        out.append((rise_db, max(rise_ms, 2.5)))
    return out


def pulse_drops(x, events, t0, t1, band=None):
    """Per event with ≥0.5 s to the next event inside [t0, t1): the dB the
    envelope falls from its post-onset peak to the trough just before the
    next onset. The signature of pluck-shaped (vs smeared) temporal
    behavior; paired ref/candidate by event index. `band=(lo, hi)`
    measures a bandpassed envelope — smear is most audible in the upper
    harmonics, which decay fastest in a real tanpura."""
    seg = x[int(t0 * SR):int(t1 * SR)]
    if band is not None:
        sos = signal.butter(4, band, btype="band", fs=SR, output="sos")
        seg = signal.sosfilt(sos, seg)
    env = wideband_env_db(seg)
    hop = 0.025
    times = sorted(e["at"] for e in events if t0 <= e["at"] < t1 - 0.3)
    drops = []
    for i, te in enumerate(times):
        tn = times[i + 1] if i + 1 < len(times) else t1
        if tn - te < 0.5:
            drops.append(None)
            continue
        a = int((te - t0) / hop)
        b = min(int((tn - t0) / hop), len(env))
        if b - a < 8 or a < 0:
            drops.append(None)
            continue
        peak = env[a:min(a + int(0.30 / hop), b)].max()
        trough = env[max(a, b - int(0.25 / hop)):b].min()
        drops.append(float(peak - trough))
    return drops


def load_weights():
    p = os.path.join(TDIR, "loss_weights.json")
    if os.path.exists(p):
        w = dict(DEFAULT_WEIGHTS)
        w.update(json.load(open(p)))
        return w
    return DEFAULT_WEIGHTS


def log_band_ltas(x, sr=SR, bands=120, fmin=60, fmax=11000):
    f, P = signal.welch(x, sr, nperseg=8192, noverlap=4096)
    edges = np.geomspace(fmin, fmax, bands + 1)
    out = np.zeros(bands)
    for i in range(bands):
        m = (f >= edges[i]) & (f < edges[i + 1])
        out[i] = P[m].mean() if m.any() else 1e-15
    return 10 * np.log10(out + 1e-15)


def wideband_env_db(x, sr=SR, hop=0.025, win=0.05):
    hn, wn = int(hop * sr), int(win * sr)
    n = (len(x) - wn) // hn
    e = np.array([np.sqrt((x[i * hn:i * hn + wn] ** 2).mean()) for i in range(n)])
    return 20 * np.log10(e + 1e-7)


def harm_loss_for_string(ref_mat, cand_mat, hop=ENV_HOP):
    """Per-harmonic envelope distance + peak-time error, gain-weighted."""
    n_k = min(ref_mat.shape[0], cand_mat.shape[0])
    m = min(ref_mat.shape[1], cand_mat.shape[1])
    ref, cand = ref_mat[:n_k, :m], cand_mat[:n_k, :m]
    peak_ref = ref.max() or 1.0
    peak_cand = cand.max() or 1.0
    ref = ref / peak_ref
    cand = cand / peak_cand
    w = np.maximum(ref.max(axis=1), 1e-4)
    w = w / w.sum()
    env_err = 0.0
    tp_err = 0.0
    for k in range(n_k):
        r_db = 20 * np.log10(np.maximum(ref[k], 1e-4))
        c_db = 20 * np.log10(np.maximum(cand[k], 1e-4))
        env_err += w[k] * np.abs(r_db - c_db).mean()
        if ref[k].max() > 1e-3 and cand[k].max() > 1e-3:
            tp_r = np.argmax(ref[k]) * hop
            tp_c = np.argmax(cand[k]) * hop
            tp_err += w[k] * abs(np.log((tp_c + 0.05) / (tp_r + 0.05)))
    return env_err + 20.0 * tp_err


def compute_loss(cand_path, ref_model, npz, windows=None, harm=True,
                 strings_filter=None, iso_path=None, ref_wav=None,
                 cache_ns="main", floor_db=None, weights_override=None):
    """Loss of a candidate rendered with the SAME pluck schedule as the
    reference measurement.

    - harm/t60: the candidate goes through the identical pluck-synchronous
      stacking operator as the reference; per-harmonic envelope distance and
      gain-weighted log-decay mismatch. Measurement biases (drone bed,
      cycle regularity) appear on both sides and cancel to first order.
    - texture (windows): LTAS, wideband envelope, per-band modulation depth
      over reference-time windows.
    - smooth: paired isolated-pluck envelope smoothness (the wah-wah guard;
      only references with ≥1.8 s inter-pluck gaps contribute).

    Multi-reference: pass ref_wav + a unique cache_ns per auxiliary
    reference (refs/<name>); the default is the main tanpura.mp3 set.
    """
    w = load_weights()
    if weights_override:
        w = dict(w)
        w.update(weights_override)
    floor = SPECRES_FLOOR_DB if floor_db is None else floor_db
    comps = {}
    ref = _REF_CACHE.get(("x", cache_ns))
    if ref is None:
        ref = load_wav_mono(ref_wav or REF_WAV)
        _REF_CACHE[("x", cache_ns)] = ref
    cand = load_wav_mono(cand_path)

    cand_dur = len(cand) / SR
    events = [e for e in ref_model["events"] if e["at"] + 0.35 < cand_dur]
    f0s = ref_model["f0s"]

    if harm and w.get("harm"):
        # Per-harmonic bloom shape, restricted to the densely-supported
        # first 1.2 s after onset, on BED-SUBTRACTED matrices both sides
        # (attribution-corrected; the reference NPZ must come from
        # `rematrix`, which applies the same operator). Ring-out is NOT
        # judged here — the stacking truncates at the next event.
        early = int(1.2 / ENV_HOP)
        cand_mats, _ = stacked_harmonics(cand, events, f0s, bed_subtract=True)
        harm_l = 0.0
        n = 0
        for sidx in (0, 1, 3):
            if strings_filter is not None and sidx not in strings_filter:
                continue
            key = f"string{sidx}"
            if key not in npz or sidx not in cand_mats:
                continue
            harm_l += harm_loss_for_string(npz[key][:, :early],
                                           cand_mats[sidx][:, :early])
            n += 1
        comps["harm"] = harm_l / max(n, 1)

    if windows:
        acc = {k: 0.0 for k in ("ltas", "env", "mod", "spec", "pulse", "specres",
                                "tune", "attack")}
        on = {k: bool(w.get(k)) for k in acc}
        for (t0, t1) in windows:
            i0, i1 = int(t0 * SR), int(t1 * SR)
            r, c = ref[i0:i1], cand[i0:i1]
            m = min(len(r), len(c))
            r, c = r[:m], c[:m]
            if on["specres"]:
                # The acceptance-bar metric: per-cell |ΔdB| on ABSOLUTE,
                # loudness-matched grids; slow/std split per specres_eval.
                key = ("specres", cache_ns, t0, t1, m)
                if key not in _REF_CACHE:
                    rn = r / (np.sqrt((_hp90(r) ** 2).mean()) + 1e-12)
                    _REF_CACHE[key] = abs_logspec_bands(rn)
                A = _REF_CACHE[key]
                cn = c / (np.sqrt((_hp90(c) ** 2).mean()) + 1e-12)
                B = abs_logspec_bands(cn)
                tt = min(A.shape[1], B.shape[1])
                A2, B2 = A[:, :tt], B[:, :tt]
                pk = A2.max()
                cw = np.clip((np.maximum(A2, B2) - (pk - floor))
                             / floor, 0.0, 1.0)
                acc["specres"] += specres_eval(A2, B2, cw)["total"]
            if on["tune"]:
                acc["tune"] += tune_error(r, c) / 8.0  # 8 mean cents = 1 pt
            if on["attack"]:
                akey = ("attack", cache_ns, t0, t1)
                if akey not in _REF_CACHE:
                    _REF_CACHE[akey] = attack_stats(ref, ref_model["events"], t0, t1)
                ar = _REF_CACHE[akey]
                ac = attack_stats(cand, events, t0, t1)
                pairs = [(p, q) for p, q in zip(ar, ac)
                         if p is not None and q is not None]
                if pairs:
                    d_rise = np.mean([abs(p[0] - q[0]) for p, q in pairs])
                    d_time = np.mean([abs(np.log(p[1] / q[1])) for p, q in pairs])
                    acc["attack"] += float(d_rise / 4.0 + d_time)
            # RMS normalize both for the legacy texture terms.
            r = r / (np.sqrt((r ** 2).mean()) + 1e-9)
            c = c / (np.sqrt((c ** 2).mean()) + 1e-9)
            if on["ltas"]:
                acc["ltas"] += np.abs(log_band_ltas(r) - log_band_ltas(c)).mean()
            if on["env"]:
                er, ec = wideband_env_db(r), wideband_env_db(c)
                mm = min(len(er), len(ec))
                acc["env"] += np.abs(er[:mm] - ec[:mm]).mean()
            if on["spec"]:
                # Mean-removed band trajectories (subsumed by specres).
                key = ("spec", cache_ns, t0, t1, m)
                if key not in _REF_CACHE:
                    _REF_CACHE[key] = logspec_bands(r)
                sr_mat = _REF_CACHE[key]
                sc_mat = logspec_bands(c)
                tt = min(sr_mat.shape[1], sc_mat.shape[1])
                acc["spec"] += np.abs(sr_mat[:, :tt] - sc_mat[:, :tt]).mean()
            if on["pulse"]:
                # Paired per-event decay drops (peak → pre-next-onset
                # trough), wideband + upper-harmonic + sheen bands (the
                # 3.2–8 kHz band keeps the run-1 organ exploit closed in
                # the newly reachable HF region).
                for band in (None, (800.0, 3200.0), (3200.0, 8000.0)):
                    pkey = ("pulse", cache_ns, t0, t1, band)
                    if pkey not in _REF_CACHE:
                        _REF_CACHE[pkey] = pulse_drops(ref, ref_model["events"], t0, t1, band)
                    dr = _REF_CACHE[pkey]
                    dc = pulse_drops(cand, events, t0, t1, band)
                    pairs = [(a, b) for a, b in zip(dr, dc) if a is not None and b is not None]
                    if pairs:
                        acc["pulse"] += float(np.mean([abs(a - b) for a, b in pairs])) / 3.0
            if on["mod"]:
                # Per-octave-band envelope fluctuation (jiva pulse).
                for (lo, hi) in ((200, 400), (400, 800), (800, 1600), (1600, 3200)):
                    sos = signal.butter(4, [lo, hi], btype="band", fs=SR, output="sos")
                    fr = wideband_env_db(signal.sosfilt(sos, r))
                    fc = wideband_env_db(signal.sosfilt(sos, c))
                    acc["mod"] += abs(np.std(fr) - np.std(fc)) / 4
        nw = len(windows)
        for k in acc:
            if on[k]:
                comps[k] = acc[k] / nw

    if w.get("smooth"):
        # The wah-wah guard: paired isolated-pluck envelope smoothness,
        # wideband + mid-band (jiva lives mid-band). Only references with
        # ≥1.8 s inter-pluck gaps contribute — the sparse aux samples are
        # exactly what carries this signal (dense strumming masks it).
        bands = (None, (500.0, 3000.0))
        skey = ("smooth", cache_ns, len(events))
        if skey not in _REF_CACHE:
            _REF_CACHE[skey] = [pluck_smoothness(ref, events, band=b)
                                for b in bands]
        tot, n = 0.0, 0
        for bi, b in enumerate(bands):
            rv = _REF_CACHE[skey][bi]
            if not any(v is not None for v in rv):
                break  # no isolated plucks in this reference at all
            cv = pluck_smoothness(cand, events, band=b)
            for a, cval in zip(rv, cv):
                if a is not None and cval is not None:
                    tot += abs(a - cval)
                    n += 1
        if n:
            comps["smooth"] = tot / n

    if iso_path is not None:
        comps["ring"] = ring_loss(iso_path, ref_model)
        if w.get("modspec"):
            comps["modspec"] = modspec_loss(iso_path)
        if w.get("isosmooth"):
            # ABSOLUTE wah-wah guard at the model's own tuning: the iso
            # render's plucks are fully isolated by construction. The
            # paired smooth term only constrains the aux tunings; the
            # complaint was heard at ours. Allowance 1.2 dB ≈ the upper
            # end of the 8 references' measured range.
            ix = _REF_CACHE.get(("isox", iso_path))
            iso_x = load_wav_mono(iso_path)
            iso_ev = [{"at": t} for t, _s in ISO_PLUCKS]
            tot, n = 0.0, 0
            for b in (None, (500.0, 3000.0)):
                for v in pluck_smoothness(iso_x, iso_ev, band=b):
                    if v is not None:
                        tot += max(0.0, v - 1.2)
                        n += 1
            comps["isosmooth"] = tot / max(n, 1)

    # Measured on the raw (un-normalized) render: time spent at/over the
    # limiter knee. The reference (and any sane render) scores 0.
    comps["clip"] = float((np.abs(cand) > 0.84).mean())

    total = sum(w[k] * v for k, v in comps.items())
    return {"total": float(total), "components": {k: float(v) for k, v in comps.items()},
            "weights": {k: w[k] for k in comps}}


def cmd_loss(args):
    ref_model = json.load(open(REF_MODEL))
    npz = dict(np.load(REF_NPZ))
    windows = None
    if args.windows:
        windows = [tuple(map(float, w.split(":"))) for w in args.windows.split(",")]
    out = compute_loss(args.candidate, ref_model, npz, windows=windows,
                       harm=not args.no_harm, iso_path=args.iso)
    print(json.dumps(out, indent=1))


# ---------------------------------------------------------------------------
# Spectrogram PNG (no matplotlib)

def write_png(path, rgb):
    h, w_, _ = rgb.shape
    raw = b"".join(b"\x00" + rgb[y].tobytes() for y in range(h))

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", w_, h, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(raw, 6))
           + chunk(b"IEND", b""))
    atomic_write(path, png)


def colormap(v):
    """v in [0,1] -> RGB (simple magma-ish ramp)."""
    stops = np.array([[0, 0, 4], [40, 11, 84], [121, 28, 109], [203, 62, 78],
                      [247, 137, 74], [252, 224, 165]], dtype=float)
    pos = np.linspace(0, 1, len(stops))
    r = np.interp(v, pos, stops[:, 0])
    g = np.interp(v, pos, stops[:, 1])
    b = np.interp(v, pos, stops[:, 2])
    return np.stack([r, g, b], axis=-1).astype(np.uint8)


def logspec_image(x, sr=SR, height=360, fmin=55, fmax=8000, max_cols=900):
    f, t, Z = signal.stft(x, sr, nperseg=4096, noverlap=4096 - 1024)
    mag = 20 * np.log10(np.abs(Z) + 1e-9)
    rows = np.geomspace(fmin, fmax, height)
    idx = np.searchsorted(f, rows)
    img = mag[np.clip(idx, 0, len(f) - 1)]
    if img.shape[1] > max_cols:
        step = img.shape[1] // max_cols
        img = img[:, ::step]
    lo, hi = np.percentile(img, 5), np.percentile(img, 99.5)
    v = np.clip((img - lo) / max(hi - lo, 1e-9), 0, 1)
    return colormap(v[::-1])  # low freq at bottom


def cmd_refine_schedule(args):
    """EXPERIMENTAL render-based attribution refinement. Onset TIMES from
    flux are trusted (±12 ms); LABELS are tested by rendering each event's
    local context with all three pitch options and keeping the label whose
    render best matches the reference spectrogram locally.

    CAVEAT — known bias: in a broadband spectral comparison the SA (C3)
    hypothesis is a hedge, because C3's harmonic series is a superset of
    the others' main rows (C4 ⊂ its evens, G3 collides at multiples of 3).
    On this reference it flipped 29/86 labels, 55 of them to SA — almost
    certainly over-attribution. The fundamental-jump attribution in
    detect_plucks (median margin ~5 dB) is the canonical labeling; use
    this only with a hypothesis-discriminative band set.
    """
    import subprocess
    render_bin = os.path.join(REPO, "Packages", "StarpadDSP", ".build",
                              "release", "tanpura-render")
    model = json.load(open(REF_MODEL))
    events = model["events"]
    ref = load_wav_mono(REF_WAV)
    params = json.load(open(args.params)) if args.params else None

    def local_spec(x, a, b):
        return logspec_bands(x[int(a * SR):int(b * SR)], bands=72, fmin=100, fmax=3000)

    changed = 0
    for idx, e in enumerate(events):
        t = e["at"]
        a, b = max(0.0, t - 0.4), t + 1.4
        ref_mat = local_spec(ref, a, b)
        ctx = [ev for ev in events if t - 3.0 <= ev["at"] <= b]
        scores = {}
        for lab in (0, 1, 3):
            plucks = []
            for ev in ctx:
                s = lab if ev["at"] == t else (1 if ev["string"] == 2 else ev["string"])
                plucks.append({"at": ev["at"] - (t - 3.0),
                               "string": s,
                               "velocity": ev.get("velocity", 0.8)})
            spec = {"durationSeconds": b - (t - 3.0) + 0.1, "seed": 4242,
                    "plucks": plucks, "out": "/tmp/refine.wav"}
            if params:
                spec["params"] = params
            with open("/tmp/refine.json", "w") as fh:
                json.dump(spec, fh)
            subprocess.run([render_bin, "/tmp/refine.json", "--mono"],
                           check=True, capture_output=True)
            cand = load_wav_mono("/tmp/refine.wav")
            c_mat = local_spec(cand, a - (t - 3.0), b - (t - 3.0))
            tt = min(ref_mat.shape[1], c_mat.shape[1])
            scores[lab] = float(np.abs(ref_mat[:, :tt] - c_mat[:, :tt]).mean())
        cur = 1 if e["string"] == 2 else e["string"]
        best = min(scores, key=scores.get)
        # Flip only on a clear margin; ties keep the fundamental-jump call.
        if best != cur and scores[best] < scores[cur] * 0.97:
            e["string"] = best
            changed += 1
        if (idx + 1) % 20 == 0:
            print(f"  {idx + 1}/{len(events)} events, {changed} flips so far",
                  flush=True)

    # Re-alternate the unison sa pair.
    flip = 0
    for e in events:
        if e["string"] in (1, 2):
            e["string"] = 1 + (flip % 2)
            flip += 1
    counts = {}
    for e in events:
        counts[e["string"]] = counts.get(e["string"], 0) + 1
    print(f"refined: {changed} labels changed; per-string {counts}")
    atomic_write_json(REF_MODEL, model)
    print(REF_MODEL)


def cmd_schedule_check(args):
    """Verify the detected schedule against the audio itself: an overlay
    PNG (events marked at their string's fundamental row) plus coverage
    stats against an independent HF-flux onset detector."""
    model = json.load(open(REF_MODEL))
    x = load_wav_mono(REF_WAV)
    dur = min(args.duration, len(x) / SR)
    seg = x[:int(dur * SR)]
    img = logspec_image(seg, height=420, fmin=55, fmax=8000, max_cols=2000).copy()
    h, w_, _ = img.shape

    def row_of(freq):
        pos = (np.log(freq / 55) / np.log(8000 / 55)) * (h - 1)
        return int(h - 1 - pos)

    colors = {0: (90, 255, 120), 1: (90, 200, 255), 2: (90, 200, 255),
              3: (255, 255, 255)}
    for e in model["events"]:
        if e["at"] > dur:
            break
        cx = int(e["at"] / dur * (w_ - 1))
        r = row_of(model["f0s"][e["string"]])
        col = colors[e["string"]]
        for dy in range(-10, 11):
            rr = r + dy
            if 0 <= rr < h:
                img[rr, cx] = col
                if cx + 1 < w_:
                    img[rr, cx + 1] = col
        for rr in range(0, 12):  # top tick for quick scanning
            img[rr, cx] = col
    write_png(args.out, img)

    # Coverage vs independent HF-flux onsets.
    f, _, Z = signal.stft(x, SR, nperseg=2048, noverlap=2048 - 512)
    hf = np.abs(Z)[(f > 1200) & (f < 9000)].sum(axis=0)
    flux = np.diff(np.maximum(hf, 0), prepend=hf[0])
    flux[flux < 0] = 0
    flux = signal.convolve(flux, np.ones(3) / 3, mode="same")
    fhop = 512 / SR
    peaks, _ = signal.find_peaks(flux, height=np.percentile(flux, 92),
                                 distance=int(0.25 / fhop))
    onsets = peaks * fhop
    ev = np.array([e["at"] for e in model["events"]])
    matched = sum(1 for o in onsets if np.abs(ev - o).min() < 0.08)
    orphans = sum(1 for t in ev if np.abs(onsets - t).min() > 0.08)
    counts = {}
    for e in model["events"]:
        counts[e["string"]] = counts.get(e["string"], 0) + 1
    print(f"schedule: {len(ev)} events, per-string {counts}")
    print(f"flux onsets matched: {matched}/{len(onsets)}; "
          f"scheduled events with no flux onset: {orphans}/{len(ev)}")
    print(args.out)


def cmd_spectrogram(args):
    imgs = []
    for path in [args.ref or REF_WAV] + args.candidates:
        imgs.append(logspec_image(load_wav_mono(path)))
    h = max(i.shape[0] for i in imgs)
    gap = np.full((h, 4, 3), 255, dtype=np.uint8)
    cols = []
    for i, im in enumerate(imgs):
        if im.shape[0] < h:
            pad = np.zeros((h - im.shape[0], im.shape[1], 3), dtype=np.uint8)
            im = np.vstack([im, pad])
        cols.append(im)
        if i < len(imgs) - 1:
            cols.append(gap)
    write_png(args.out, np.hstack(cols))
    print(args.out)


def cmd_report(args):
    """Acceptance-bar report: stacked PNG (reference grid / candidate grid /
    weighted per-cell residual map, shared dB scale) + specres stats per
    window. With --floor (a second render of the SAME params, different
    seed) it also prints the stochastic floor — the residual below which
    only seed luck differs. The bar: residual map near-black, specres
    within ~1–2 dB of the floor."""
    ref = load_wav_mono(REF_WAV)
    cand = load_wav_mono(args.candidate)
    windows = [(4.0, 8.0), (8.0, 18.0), (20.0, 30.0)]
    if args.windows:
        windows = [tuple(map(float, w.split(":"))) for w in args.windows.split(",")]
    stats = {}
    for (t0, t1) in windows:
        i0, i1 = int(t0 * SR), int(t1 * SR)
        m = min(len(ref) - i0, len(cand) - i0, i1 - i0)
        A, B, w = specres_grids(ref[i0:i0 + m], cand[i0:i0 + m])
        d = np.abs(A - B)
        act = w > 0
        quiet = (w > 0.05) & (w < 0.3)  # audible bed/hiss cells the
        # loud-cell-dominant weighting under-weights — report-only
        parts = specres_eval(A, B, w)
        stats[f"{t0}-{t1}s"] = {
            "specres": round(parts["total"], 2),
            "slow": round(parts["slow"], 2),
            "std": round(parts["std"], 2),
            "active_mean": round(float(d[act].mean()), 2),
            "p90": round(float(np.percentile(d[act], 90)), 2),
            "quiet_cells": round(float(d[quiet].mean()), 2) if quiet.any() else 0.0,
            "tune_cents": round(tune_error(ref[i0:i0 + m], cand[i0:i0 + m]), 1),
        }
    if args.floor:
        fl = load_wav_mono(args.floor)
        vals = []
        for (t0, t1) in windows:
            i0, i1 = int(t0 * SR), int(t1 * SR)
            m = min(len(fl) - i0, len(cand) - i0, i1 - i0)
            A, B, w = specres_grids(cand[i0:i0 + m], fl[i0:i0 + m])
            vals.append(specres_score(A, B, w))
        stats["stochastic_floor"] = round(float(np.mean(vals)), 2)
    print(json.dumps(stats, indent=1))

    # Image over the full span: ref / candidate / weighted residual.
    t0, t1 = (windows[0][0], windows[-1][1]) if not args.span else \
        tuple(map(float, args.span.split(":")))
    i0, i1 = int(t0 * SR), int(t1 * SR)
    m = min(len(ref) - i0, len(cand) - i0, i1 - i0)
    r, c = ref[i0:i0 + m], cand[i0:i0 + m]
    rn = r / (np.sqrt((_hp90(r) ** 2).mean()) + 1e-12)
    cn = c / (np.sqrt((_hp90(c) ** 2).mean()) + 1e-12)
    A = abs_logspec_bands(rn, bands=192)
    B = abs_logspec_bands(cn, bands=192)
    tt = min(A.shape[1], B.shape[1])
    A, B = A[:, :tt], B[:, :tt]
    pk = A.max()
    w = np.clip((np.maximum(A, B) - (pk - SPECRES_FLOOR_DB)) / SPECRES_FLOOR_DB,
                0.0, 1.0)
    lo = pk - 78.0
    panels = [np.clip((A - lo) / (pk - lo), 0, 1),
              np.clip((B - lo) / (pk - lo), 0, 1),
              np.clip(np.abs(A - B) * w / 30.0, 0, 1)]  # 30 dB residual = full scale
    gap = np.full((4, tt, 3), 255, dtype=np.uint8)
    rows = []
    for i, pnl in enumerate(panels):
        rows.append(colormap(pnl[::-1]))
        if i < len(panels) - 1:
            rows.append(gap)
    out = args.out or os.path.join(TDIR, "report.png")
    write_png(out, np.vstack(rows))
    print(out)

    if args.diff_audio:
        # Perceptual diff artifacts. A literal waveform diff cannot work
        # here — the synth's partials have random phase, so ref−cand always
        # sounds like two tanpuras. The honest equivalent: resynthesize the
        # MAGNITUDE spectrogram difference. missing = energy the reference
        # has that the candidate lacks (ref phase); extra = energy the
        # candidate adds (candidate phase). Both fall to silence as the
        # match approaches the bar.
        f, t, R = signal.stft(rn, SR, nperseg=4096, noverlap=4096 - 1024)
        _, _, C = signal.stft(cn, SR, nperseg=4096, noverlap=4096 - 1024)
        tt2 = min(R.shape[1], C.shape[1])
        R, C = R[:, :tt2], C[:, :tt2]
        d = np.abs(R) - np.abs(C)
        for name, mag, ph in (("missing", np.maximum(d, 0), np.angle(R)),
                              ("extra", np.maximum(-d, 0), np.angle(C))):
            _, y = signal.istft(mag * np.exp(1j * ph), SR,
                                nperseg=4096, noverlap=4096 - 1024)
            y = y / (np.abs(y).max() + 1e-9) * 0.7
            path = os.path.join(TDIR, f"diff_{name}.wav")
            with wave.open(path + ".tmp", "wb") as wf:
                wf.setnchannels(1)
                wf.setsampwidth(2)
                wf.setframerate(SR)
                wf.writeframes((y * 32767).astype(np.int16).tobytes())
            os.replace(path + ".tmp", path)
            print(path)


# ---------------------------------------------------------------------------
# make-score: AuditionScore for in-app verification

def cmd_make_score(args):
    ref_model = json.load(open(REF_MODEL))
    params = json.load(open(args.params)) if args.params else None
    # Pin the ENTIRE master chain, not just reverb: the score must sound
    # identical regardless of the user's persisted FX state (a persisted
    # filterCutoff once cost 10 dB of specres in "verification").
    events = [
        {"at": 0.0, "kind": "voiceParam", "param": "reverbMix", "value": 0.0},
        {"at": 0.0, "kind": "voiceParam", "param": "filterCutoff", "value": 20000.0},
        {"at": 0.0, "kind": "voiceParam", "param": "filterResonance", "value": 0.0},
        # The drone's post-model makeup gain (default +12 dB) would clip
        # the recording tap and shift levels vs the offline render.
        {"at": 0.0, "kind": "voiceParam", "param": "tanpuraGainDB", "value": 0.0},
    ]
    if params:
        # Flatten params into tanpura.* voiceParam events.
        def emit(path, v):
            events.append({"at": 0.0, "kind": "voiceParam",
                           "param": f"tanpura.{path}", "value": float(v)})
        for key, v in params.items():
            if key.startswith("_"):
                continue  # optimizer bookkeeping (e.g. _saF0Center), not a param
            if key == "strings":
                for i, s in enumerate(v):
                    for f, fv in s.items():
                        if isinstance(fv, list):
                            for k, item in enumerate(fv):
                                emit(f"string{i}.{f}{k}", item)
                        else:
                            emit(f"string{i}.{f}", fv)
            elif key == "body":
                for i, band in enumerate(v):
                    for f, fv in band.items():
                        emit(f"body{i}.{f}", fv)
            else:
                emit(key, v)
    # Keep the reference's own timeline so the rendered WAV stays
    # time-aligned with the reference measurement in `loss`.
    t_end = args.duration or 20.0
    for e in ref_model["events"]:
        if e["at"] > t_end:
            break
        events.append({"at": e["at"], "kind": "tanpuraPluck",
                       "index": e["string"], "value": e.get("velocity", 0.8)})
    score = {"name": args.name, "tailSeconds": 4.0, "events": events}
    atomic_write_json(args.out, score)
    print(args.out)


# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("decode-ref")
    p.add_argument("--mp3", default=None)
    p.set_defaults(fn=cmd_decode_ref)

    p = sub.add_parser("calibrate")
    p.set_defaults(fn=cmd_calibrate)

    p = sub.add_parser("calibrate-aux")
    p.add_argument("input", help="sample wav/mp3 (any rate/channels)")
    p.add_argument("--name", default=None)
    p.set_defaults(fn=cmd_calibrate_aux)

    p = sub.add_parser("rematrix")
    p.add_argument("--n-harm", type=int, default=48,
                   help="measured harmonics per string (synthesis cap is 64)")
    p.set_defaults(fn=cmd_rematrix)

    p = sub.add_parser("fit-init")
    p.add_argument("--out", default=None)
    p.set_defaults(fn=cmd_fit_init)

    p = sub.add_parser("loss")
    p.add_argument("candidate")
    p.add_argument("--windows", default=None,
                   help="texture windows 't0:t1,t0:t1' in reference seconds")
    p.add_argument("--no-harm", action="store_true",
                   help="skip the per-harmonic (schedule-stacked) components")
    p.add_argument("--iso", default=None,
                   help="isolated-pluck render WAV for the ring-time loss")
    p.set_defaults(fn=cmd_loss)

    p = sub.add_parser("refine-schedule")
    p.add_argument("--params", default=os.path.join(TDIR, "best_params.json"))
    p.set_defaults(fn=cmd_refine_schedule)

    p = sub.add_parser("schedule-check")
    p.add_argument("--duration", type=float, default=30.0)
    p.add_argument("-o", "--out",
                   default=os.path.join(TDIR, "schedule_overlay.png"))
    p.set_defaults(fn=cmd_schedule_check)

    p = sub.add_parser("spectrogram")
    p.add_argument("candidates", nargs="*")
    p.add_argument("--ref", default=None)
    p.add_argument("-o", "--out", required=True)
    p.set_defaults(fn=cmd_spectrogram)

    p = sub.add_parser("report")
    p.add_argument("candidate")
    p.add_argument("--floor", default=None,
                   help="same-params different-seed render for the stochastic floor")
    p.add_argument("--windows", default=None,
                   help="stat windows 't0:t1,t0:t1' (default 8:18,20:30)")
    p.add_argument("--span", default=None,
                   help="image span 't0:t1' (default first window start to last end)")
    p.add_argument("--diff-audio", action="store_true",
                   help="write diff_missing.wav / diff_extra.wav (magnitude-"
                        "spectrogram diff resynthesis over the image span)")
    p.add_argument("-o", "--out", default=None)
    p.set_defaults(fn=cmd_report)

    p = sub.add_parser("make-score")
    p.add_argument("--params", default=None)
    p.add_argument("--name", default="tanpura-verify")
    p.add_argument("--duration", type=float, default=20.0)
    p.add_argument("-o", "--out",
                   default=os.path.join(REPO, "auditions", "inbox", "tanpura-verify.json"))
    p.set_defaults(fn=cmd_make_score)

    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
