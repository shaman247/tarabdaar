#!/usr/bin/env python3
"""Sitar reference measurement + perceptual loss for the matching loop.

The sitar tone is the SAME harmonic-resolved plucked-string model as the
tanpura (`Packages/StarpadDSP`), fitted to `sitar1.wav` — three plucks of a
single note (C#4, 280.4 Hz; the user's call: all three are the same note).
Its eventual home is the sympathetic-string layer, so we fit ONE pitch-
invariant string timbre to all three plucks.

This tool reuses tanpura_match's signal-agnostic specres / tune / attack
machinery (the acceptance-bar loss) and adds:
  analyze    print onsets, f0, per-harmonic spectrum (diagnostic)
  fit-init   measure the per-harmonic gain profile of the 280.4 Hz note and
             calibrate gainTrimDB so the model's rendered spectrum matches,
             plus measured decay/peak laws -> auditions/sitar/init.json
  loss       score a candidate WAV against sitar1.wav
  report     side-by-side spectrogram PNG + specres stats
  make-score emit an AuditionScore JSON for in-app verification

Only numpy/scipy. Atomic writes throughout.
"""

import argparse
import json
import os
import subprocess
import sys

import numpy as np
from scipy import signal

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tanpura_match as tm  # noqa: E402  reuse specres/tune/IO/PNG

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SDIR = os.path.join(REPO, "auditions", "sitar")
REF_WAV = os.path.join(REPO, "sitar1.wav")
INIT = os.path.join(SDIR, "init.json")
REF_MODEL = os.path.join(SDIR, "reference_model.json")
BEST = os.path.join(SDIR, "best_params.json")
RENDER_BIN = os.path.join(REPO, "Packages", "StarpadDSP", ".build",
                          "release", "tanpura-render")

SR = tm.SR  # 44100

# ---- The reference: three plucks of C#4, single re-plucked string. --------
F0 = 280.4
ONSETS = [0.05, 1.415, 3.026]
VELS = [0.82, 1.0, 0.94]
DUR = 3.529                      # sitar1.wav length
EVENTS = [{"at": t, "string": 0, "velocity": v}
          for t, v in zip(ONSETS, VELS)]


# ---------------------------------------------------------------------------
# I/O

def load_ref():
    return tm.load_wav_mono(REF_WAV)


def render(params, out, dur=DUR, seed=0x5EED_1A4B, events=None):
    spec = {"durationSeconds": dur, "seed": seed, "params": params,
            "plucks": events if events is not None else EVENTS, "out": out}
    sp = out + ".spec.json"
    tm.atomic_write_json(sp, spec)
    r = subprocess.run([RENDER_BIN, sp, "--mono"], capture_output=True,
                       text=True)
    os.remove(sp)
    if r.returncode != 0:
        raise SystemExit(f"render failed: {r.stderr}")
    return tm.load_wav_mono(out)


def default_params():
    out = subprocess.run([RENDER_BIN, "--print-defaults"],
                         capture_output=True, text=True, check=True)
    return json.loads(out.stdout)


# ---------------------------------------------------------------------------
# Per-harmonic measurement (heterodyne, reusing tanpura_match)

def harmonic_profile(x, f0, onsets, n_harm=44, pre=0.0, span=1.0):
    """Per-harmonic measurement averaged over the plucks.

    For each harmonic k, heterodyne out its envelope, slice each pluck's
    window [onset, onset+span], and return:
      gain_db[k]  peak level over the window, dB, averaged across plucks
      peak_s[k]   time of the peak after the onset, s (bloom proxy)
      tau_s[k]    e-fold decay time fitted peak->window end, s
    """
    A = tm.measure_envelope_matrix(x, f0, n_harm=n_harm, sr=SR)  # [k, t]
    hop = tm.ENV_HOP
    nh = A.shape[0]
    gains = np.full(nh, -120.0)
    peaks = np.full(nh, 0.02)
    taus = np.full(nh, 1.0)
    for k in range(nh):
        env = A[k]
        pk_vals, pk_ts, tau_vals = [], [], []
        for j, t0 in enumerate(onsets):
            s = int((t0 + pre) / hop)
            e = int(min(DUR, t0 + span) / hop) if j + 1 >= len(onsets) \
                else int(min(onsets[j + 1], t0 + span) / hop)
            seg = env[s:e]
            if len(seg) < 4:
                continue
            ipk = int(np.argmax(seg))
            pk = seg[ipk]
            if pk <= 1e-6:
                continue
            pk_vals.append(pk)
            pk_ts.append(ipk * hop)
            # e-fold tau: log-linear fit from peak to where it drops 12 dB
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
                        tau_vals.append(-1.0 / sl)
        if pk_vals:
            gains[k] = 20 * np.log10(np.mean(pk_vals))
            peaks[k] = float(np.median(pk_ts))
        if tau_vals:
            taus[k] = float(np.median(tau_vals))
    return gains, peaks, taus


# ---------------------------------------------------------------------------
# fit-init: calibrate the model's rendered spectrum to the reference

def model_harmonic_gains(params, n_harm=44):
    """Render the model and measure its per-harmonic peak levels (dB)."""
    tmp = os.path.join(SDIR, "work", "_fitcal.wav")
    x = render(params, tmp)
    g, _, _ = harmonic_profile(x, F0, ONSETS, n_harm=n_harm)
    try:
        os.remove(tmp)
    except OSError:
        pass
    return g


def calibrate_gains(p, ref_g, ref0, n_harm, passes=10, damp=0.7):
    """Iteratively push gainTrimDB[k] (all strings) so the rendered model's
    per-harmonic peak spectrum matches the reference's — preserving the
    even/odd alternation a uniform group-trim can't. Damped to converge
    despite room/sub/body leakage across the heterodyne bins."""
    for it in range(passes):
        mg = model_harmonic_gains(p, n_harm=n_harm)
        kmax = int(np.argmax(ref_g))
        off = ref_g[kmax] - mg[kmax]
        moved = 0.0
        for k in range(n_harm):
            if ref_g[k] < ref0 - 55:      # below ~-55 dB: leave to falloff
                continue
            deficit = damp * ((ref_g[k]) - (mg[k] + off))
            nt = float(np.clip(p["strings"][0]["gainTrimDB"][k] + deficit,
                               -60, 24))
            moved = max(moved, abs(nt - p["strings"][0]["gainTrimDB"][k]))
            for s in p["strings"]:
                s["gainTrimDB"][k] = nt
        print(f"  gain cal pass {it}: max move {moved:.1f} dB, off {off:.1f}")
        if moved < 0.4:
            break


def set_decay_trims(p, ref_tau, ref_g, ref0, n_harm):
    """Set decayTrim[k] from the measured per-harmonic decay time so each
    harmonic rings as long as the reference's does. Floor 0.05 (not 0.2) so
    the sitar's FAST high-harmonic decay (τ ≈ 0.05 s for h24) is
    representable — the run-4 winner rang its HF ~5 dB too long because the
    trim was clamped too high."""
    base_decay = p["strings"][0]["decay"]
    dtilt = p["strings"][0]["dampTilt"]
    for k in range(n_harm):
        if ref_g[k] < ref0 - 50 or ref_tau[k] <= 0:
            continue
        law = base_decay * (k + 1) ** (-dtilt)
        trim = float(np.clip(ref_tau[k] / law, 0.05, 6.0))
        for s in p["strings"]:
            s["decayTrim"][k] = trim


def cmd_recal(args):
    """Recompute gainTrimDB + decayTrim on an existing params file from the
    reference measurement, keeping its laws/body/room/jiva. Fixes the
    even/odd alternation and the fast HF decay the frozen init missed, then
    a short CMA-ES polish can refine the rest."""
    os.makedirs(os.path.join(SDIR, "work"), exist_ok=True)
    x = load_ref()
    n_harm = args.harmonics
    ref_g, ref_pk, ref_tau = harmonic_profile(x, F0, ONSETS, n_harm=n_harm)
    ref0 = ref_g.max()
    p = json.load(open(args.params))
    for k in [k for k in p if k.startswith("_")]:
        del p[k]
    # ensure 64-long trim arrays
    for s in p["strings"]:
        s["gainTrimDB"] = (s.get("gainTrimDB", []) + [0.0] * 64)[:64]
        s["decayTrim"] = (s.get("decayTrim", []) + [1.0] * 64)[:64]
    calibrate_gains(p, ref_g, ref0, n_harm, passes=args.cal_passes)
    set_decay_trims(p, ref_tau, ref_g, ref0, n_harm)
    out = args.out or os.path.join(SDIR, "recal.json")
    tm.atomic_write_json(out, p)
    tmp = os.path.join(SDIR, "work", "_recal.wav")
    S = sys.modules[__name__]
    render(p, tmp)
    res = compute_loss(tmp)
    os.remove(tmp)
    print(f"recal -> {out}  total {res['total']:.2f}  "
          f"specres {res['components']['specres']:.2f}")


def cmd_fit_init(args):
    os.makedirs(os.path.join(SDIR, "work"), exist_ok=True)
    x = load_ref()
    n_harm = args.harmonics
    ref_g, ref_pk, ref_tau = harmonic_profile(x, F0, ONSETS, n_harm=n_harm)
    print("Reference per-harmonic (k: gain dB / peak ms / tau s):")
    ref0 = ref_g.max()
    for k in range(min(n_harm, 24)):
        print(f"  h{k+1:2d}  {ref_g[k]-ref0:6.1f}dB  {ref_pk[k]*1000:5.0f}ms"
              f"  {ref_tau[k]:5.2f}s")

    # Base params: single C#4 string (string 0), the other three silent
    # (level 0, never plucked). Start from the tanpura SA string's matched
    # timbre as a sane plucked-string prior, retuned to 280.4 Hz.
    p = default_params()
    sa = json.loads(json.dumps(p["strings"][3]))   # SA/C3 matched voice
    sa["f0"] = F0
    sa["level"] = 1.0
    sa["gainTrimDB"] = [0.0] * 64
    sa["peakTrim"] = [1.0] * 64
    sa["decayTrim"] = [1.0] * 64
    # plucked-note laws (faster decay than a drone; sharp bright attack)
    sa["decay"] = 1.6
    sa["dampTilt"] = 0.5
    sa["bloomDelay"] = 0.02
    sa["bloomSkew"] = 0.4
    sa["attackLevel"] = 0.9
    sa["attackDecay"] = 0.012
    sa["falloff"] = 0.7
    sa["pluckPos"] = 0.1
    sa["subLevelDB"] = -14.0      # jawari period-2 buzz
    sa["subFalloff"] = 1.0
    sa["subKneeH"] = 40.0
    sa["inharmonicity"] = 2e-5
    p["strings"] = [json.loads(json.dumps(sa)) for _ in range(4)]
    for i in (1, 2, 3):
        p["strings"][i]["level"] = 0.0
    # globals: a single bright pluck, modest jiva, dryish room
    p["jivaDepth"] = 0.12
    p["jivaRate"] = 4.0
    p["jivaConserve"] = 0.95
    p["jivaRateSpread"] = 0.2
    p["pitchDriftCents"] = 3.0
    p["pluckVariationDB"] = 1.5
    p["noiseLevel"] = 0.5
    p["noiseDecay"] = 0.01
    p["noiseFreq"] = 2500.0
    p["noiseQ"] = 1.2
    p["crossExcite"] = 0.0
    p["bodyDry"] = 0.7
    p["tiltDB"] = -2.0
    p["roomWetDB"] = -12.0
    p["roomDecayS"] = 0.8
    p["roomDamp"] = 0.6
    p["roomPredelayMs"] = 2.0
    p["body"] = [
        {"freq": 280.0, "gain": 0.6, "q": 4.0},
        {"freq": 560.0, "gain": 0.9, "q": 5.0},
        {"freq": 1120.0, "gain": 0.7, "q": 4.0},
    ]
    p["masterGain"] = 0.1

    # Per-harmonic gain calibration (even/odd alternation) + measured decay.
    calibrate_gains(p, ref_g, ref0, n_harm, passes=args.cal_passes)
    set_decay_trims(p, ref_tau, ref_g, ref0, n_harm)

    tm.atomic_write_json(INIT, p)
    # reference model: schedule + measured matrix for diagnostics
    tm.atomic_write_json(REF_MODEL, {
        "f0": F0, "events": EVENTS, "duration": DUR,
        "harm_gain_db": ref_g.tolist(), "harm_peak_s": ref_pk.tolist(),
        "harm_tau_s": ref_tau.tolist()})
    print(f"\nwrote {INIT}")
    print(f"wrote {REF_MODEL}")


# ---------------------------------------------------------------------------
# Loss

def wb_env_db(x, hop=0.02, win=0.04):
    return tm.wideband_env_db(x, hop=hop, win=win)


def decay_env_loss(r, c):
    """Per-pluck wideband RMS-envelope L1 in dB on the aligned schedule.
    Nails the gross decay rate that specres' slow term sees coarsely."""
    rdb = wb_env_db(r)
    cdb = wb_env_db(c)
    # level-align on the loudest 10% of reference frames
    n = min(len(rdb), len(cdb))
    rdb, cdb = rdb[:n], cdb[:n]
    thr = np.percentile(rdb, 90) - 18
    m = rdb > thr
    if m.sum() < 5:
        m = np.ones(n, bool)
    off = np.median(rdb[m] - cdb[m])
    return float(np.mean(np.abs(rdb[m] - (cdb[m] + off))))


# Specres grid focused on the band the single 280.4 Hz string can actually
# produce. Below ~200 Hz the reference has a low drone / room rumble / the
# pluck-1 fifth-below fundamental (186 Hz) and a ~258 Hz sympathetic string
# — none of which a single C#4 string makes; left in the grid they dominate
# the audibility-weighted residual (18 dB bands) and steer the fit toward
# faking content it shouldn't. fmax 13 kHz covers the sitar's bright sheen
# (h46) without chasing recording hiss above it.
SITAR_FMIN = 200.0
SITAR_FMAX = 13000.0


def sitar_specres_grids(r, c, fmin=SITAR_FMIN, fmax=SITAR_FMAX):
    sos = signal.butter(4, [fmin, fmax], btype="band", fs=SR, output="sos")
    rn = r / (np.sqrt((signal.sosfilt(sos, r) ** 2).mean()) + 1e-12)
    cn = c / (np.sqrt((signal.sosfilt(sos, c) ** 2).mean()) + 1e-12)
    A = tm.abs_logspec_bands(rn, bands=112, fmin=fmin, fmax=fmax)
    B = tm.abs_logspec_bands(cn, bands=112, fmin=fmin, fmax=fmax)
    tt = min(A.shape[1], B.shape[1])
    A, B = A[:, :tt], B[:, :tt]
    pk = A.max()
    w = np.clip((np.maximum(A, B) - (pk - tm.SPECRES_FLOOR_DB))
                / tm.SPECRES_FLOOR_DB, 0.0, 1.0)
    return A, B, w


def compute_loss(cand_wav, weights=None):
    w = {"specres": 3.0, "specres_slow": 0.0, "tune": 1.0,
         "attack": 0.6, "decay": 2.0, "pulse": 0.6}
    if weights:
        w.update(weights)
    r = load_ref()
    c = tm.load_wav_mono(cand_wav)
    n = min(len(r), len(c))
    r, c = r[:n], c[:n]
    A, B, ww = sitar_specres_grids(r, c)
    sp = tm.specres_eval(A, B, ww)
    comp = {}
    comp["specres"] = sp["total"]
    comp["specres_slow"] = sp["slow"]
    comp["specres_std"] = sp["std"]
    comp["tune"] = tm.tune_error(r, c, fmin=240.0, fmax=9000.0) / 8.0
    # attack: paired per-onset 2-8 kHz transient
    try:
        ra = tm.attack_stats(r, EVENTS, 0.0, DUR)
        ca = tm.attack_stats(c, EVENTS, 0.0, DUR)
        ds = []
        for a, b in zip(ra, ca):
            if a and b:
                ds.append(abs(a[0] - b[0]) / 6.0
                          + abs(np.log((a[1] + 1e-3) / (b[1] + 1e-3))))
        comp["attack"] = float(np.mean(ds)) if ds else 0.0
    except Exception:
        comp["attack"] = 0.0
    # pulse: per-event decay drop (wideband + two bands)
    try:
        rp = tm.pulse_drops(r, EVENTS, 0.0, DUR)
        cp = tm.pulse_drops(c, EVENTS, 0.0, DUR)
        ds = [abs(a - b) for a, b in zip(rp, cp) if a is not None and b is not None]
        comp["pulse"] = float(np.mean(ds)) / 6.0 if ds else 0.0
    except Exception:
        comp["pulse"] = 0.0
    comp["decay"] = decay_env_loss(r, c)
    total = sum(w.get(k, 0.0) * v for k, v in comp.items())
    return {"total": total, "components": comp}


def cmd_loss(args):
    res = compute_loss(args.wav)
    print(f"total {res['total']:.3f}")
    for k, v in res["components"].items():
        print(f"  {k:14s} {v:.3f}")


# ---------------------------------------------------------------------------
# Report

def cmd_report(args):
    r = load_ref()
    c = tm.load_wav_mono(args.wav)
    n = min(len(r), len(c))
    r, c = r[:n], c[:n]
    A, B, ww = sitar_specres_grids(r, c)
    sp = tm.specres_eval(A, B, ww)
    print(f"specres total {sp['total']:.2f}  slow {sp['slow']:.2f}  "
          f"std {sp['std']:.2f}")
    if args.floor:
        f = tm.load_wav_mono(args.floor)[:n]
        A2, B2, w2 = sitar_specres_grids(r, f)
        sp2 = tm.specres_eval(A2, B2, w2)
        print(f"stochastic floor (seed2) {sp2['total']:.2f}")
    print(f"tune {tm.tune_error(r, c, fmin=240, fmax=9000):.2f} cents")
    # 3-panel PNG: ref / cand / weighted residual
    img_r = tm.logspec_image(r, fmin=120, fmax=12000)
    img_c = tm.logspec_image(c, fmin=120, fmax=12000)
    h = min(img_r.shape[0], img_c.shape[0])
    wdt = min(img_r.shape[1], img_c.shape[1])
    resid = ww * np.abs(A - B)
    rr = resid[:, :wdt]
    rr = (rr / (rr.max() + 1e-9))
    rimg = np.zeros((A.shape[0], wdt, 3), np.uint8)
    for i in range(A.shape[0]):
        for j in range(wdt):
            rimg[i, j] = tm.colormap(rr[i, j])
    rimg = rimg[::-1]
    from numpy import vstack, full
    gap = full((4, wdt, 3), 255, np.uint8)
    # resize residual to image height by nearest
    ri = np.zeros((h, wdt, 3), np.uint8)
    for i in range(h):
        ri[i] = rimg[min(rimg.shape[0]-1, int(i*rimg.shape[0]/h))]
    out = args.out or os.path.join(SDIR, "report.png")
    tm.write_png(out, vstack([img_r[:h, :wdt], gap, img_c[:h, :wdt], gap, ri]))
    print(f"wrote {out}")


# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(required=True)
    p = sub.add_parser("fit-init")
    p.add_argument("--harmonics", type=int, default=48)
    p.add_argument("--cal-passes", type=int, default=12)
    p.set_defaults(fn=cmd_fit_init)
    p = sub.add_parser("recal")
    p.add_argument("params")
    p.add_argument("--harmonics", type=int, default=48)
    p.add_argument("--cal-passes", type=int, default=14)
    p.add_argument("-o", "--out", default=None)
    p.set_defaults(fn=cmd_recal)
    p = sub.add_parser("loss")
    p.add_argument("wav")
    p.set_defaults(fn=cmd_loss)
    p = sub.add_parser("report")
    p.add_argument("wav")
    p.add_argument("--floor", default=None)
    p.add_argument("-o", "--out", default=None)
    p.set_defaults(fn=cmd_report)
    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
