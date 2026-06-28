#!/usr/bin/env python3
"""Autonomous CMA-ES fit of the harmonic string model to sitar1.wav.

Reuses the tanpura optimizer's CMA-ES core (`tanpura_iterate.CMAES`, the
z<->value sigmoid maps, the Elites bookkeeping) and the sitar loss
(`sitar_match.compute_loss`). The search is simpler than the tanpura's:
ONE string timbre (string 0, the only audible voice; strings 1-3 are
silent) plus globals and body/room, scored against a single reference of
three C#4 plucks.

  python3 tools/sitar_iterate.py --init auditions/sitar/init.json \
        --gens 120 --workers 8

The low per-harmonic gainTrimDB (k<32) come from fit-init and are FROZEN;
the optimizer reaches the 8 kHz+ trims through the hfTrimDB group dim, and
reshapes the whole spectrum through falloff / pluckPos / body / sub / damp.
Winner -> auditions/sitar/best_params.json, top-10 WAV+PNG -> top/.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
import multiprocessing as mp

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import tanpura_match as tm           # noqa: E402
import sitar_match as S              # noqa: E402
from tanpura_iterate import (        # noqa: E402
    CMAES, z_to_value, value_to_z)
import tanpura_iterate as ti          # noqa: E402

# Group-trim bands: additive dB offsets on contiguous gainTrimDB slices, so
# CMA-ES can reshape the mid/high harmonic spectrum (where the residual sits)
# without 40 individual per-harmonic dims. Idempotent via a stashed base
# copy, exactly like tanpura_iterate's hfTrimDB (which owns [32:]).
GTRIM_BANDS = {"gtrim0": (4, 12), "gtrim1": (12, 20), "gtrim2": (20, 32)}
# Per-band MULTIPLIERS on decayTrim — lets CMA-ES shape the decay-time
# profile (how fast each harmonic band rings out) on top of the measured
# per-harmonic decayTrim from recal, without per-harmonic dims.
DTRIM_BANDS = {"dtrim0": (1, 8), "dtrim1": (8, 20), "dtrim2": (20, 40)}


def get_path(params, path):
    head, _, field = path.partition(".")
    if field in GTRIM_BANDS:
        base = params.get("_gtrimBase", {})
        b = base.get(field)
        if b is None:
            return 0.0
        lo, hi = GTRIM_BANDS[field]
        g = params["strings"][0]["gainTrimDB"]
        return float(np.mean(np.array(g[lo:hi]) - np.array(b)))
    if field in DTRIM_BANDS:
        base = params.get("_dtrimBase", {})
        b = base.get(field)
        if b is None:
            return 1.0
        lo, hi = DTRIM_BANDS[field]
        d = params["strings"][0]["decayTrim"]
        return float(np.mean(np.array(d[lo:hi]) / np.maximum(np.array(b), 1e-6)))
    return ti.get_path(params, path)


def set_path(params, path, value):
    head, _, field = path.partition(".")
    if field in GTRIM_BANDS:
        lo, hi = GTRIM_BANDS[field]
        base = params.setdefault("_gtrimBase", {})
        g = params["strings"][0]["gainTrimDB"]
        b = base.setdefault(field, [float(v) for v in g[lo:hi]])
        for j, bv in enumerate(b):
            g[lo + j] = float(np.clip(bv + value, -60.0, 24.0))
        return
    if field in DTRIM_BANDS:
        lo, hi = DTRIM_BANDS[field]
        base = params.setdefault("_dtrimBase", {})
        d = params["strings"][0]["decayTrim"]
        b = base.setdefault(field, [float(v) for v in d[lo:hi]])
        for j, bv in enumerate(b):
            d[lo + j] = float(np.clip(bv * value, 0.05, 8.0))
        return
    ti.set_path(params, path, value)

SDIR = S.SDIR
WORK = os.path.join(SDIR, "work")
TOP = os.path.join(SDIR, "top")
TRIALS = os.path.join(SDIR, "trials.jsonl")
RENDER_BIN = S.RENDER_BIN
RENDER_SECONDS = S.DUR
RENDER_SEED = 0x5EED_1A4B

# ---- Search space -----------------------------------------------------------
# string0 timbre + globals + body/room. masterGain pinned (RMS-normalized
# loss -> only limiter saturation observable; peak-normalized at bake).
DIMS = [
    ("string0.falloff", 0.0, 3.0, False),
    ("string0.pluckPos", 0.03, 0.45, False),
    ("string0.decay", 0.3, 6.0, True),
    ("string0.dampTilt", 0.0, 1.6, False),
    ("string0.bloomDelay", 0.005, 0.6, True),
    ("string0.bloomSkew", 0.0, 1.8, False),
    ("string0.attackLevel", 0.0, 1.0, False),
    ("string0.attackDecay", 0.005, 0.2, True),
    ("string0.inharmonicity", 1e-6, 1.2e-4, True),
    ("string0.subLevelDB", -55.0, -3.0, False),
    ("string0.subFalloff", 0.3, 3.5, False),
    ("string0.subKneeH", 2.0, 64.0, True),
    ("string0.gtrim0", -14.0, 14.0, False),
    ("string0.gtrim1", -14.0, 14.0, False),
    ("string0.gtrim2", -14.0, 14.0, False),
    ("string0.hfTrimDB", -14.0, 12.0, False),
    ("string0.dtrim0", 0.3, 3.0, True),
    ("string0.dtrim1", 0.3, 3.0, True),
    ("string0.dtrim2", 0.2, 3.0, True),
    # Jiva is for NATURAL texture only, capped low: at high depth the
    # energy-conserving redistribution starts shaping the MEAN spectrum (a
    # specres exploit that sounds like a fast tremolo/fuzz — depth 0.67 @
    # 10.6 Hz on the run-5 winner). Bounding it forces the static spectral
    # controls (gainTrim groups, body, falloff) to carry the envelope.
    ("jivaDepth", 0.0, 0.32, False),
    ("jivaRate", 1.0, 6.0, True),
    ("jivaTilt", 0.0, 1.0, False),
    ("jivaConserve", 0.85, 1.0, False),
    ("jivaRateSpread", 0.0, 0.5, False),
    ("pluckVariationDB", 0.0, 5.0, False),
    ("noiseLevel", 0.0, 1.0, False),
    ("noiseDecay", 0.003, 0.08, True),
    ("noiseFreq", 600.0, 7000.0, True),
    ("noiseQ", 0.4, 6.0, True),
    ("bodyDry", 0.1, 1.0, False),
    ("tiltDB", -10.0, 8.0, False),
    ("body0.freq", 200.0, 360.0, True),
    ("body0.gain", 0.0, 1.4, False),
    ("body0.q", 1.0, 120.0, True),
    ("body1.freq", 460.0, 720.0, True),
    ("body1.gain", 0.0, 1.4, False),
    ("body1.q", 1.0, 120.0, True),
    ("body2.freq", 900.0, 2400.0, True),
    ("body2.gain", 0.0, 1.4, False),
    ("body2.q", 1.0, 120.0, True),
    ("roomWetDB", -40.0, -4.0, False),
    ("roomDecayS", 0.15, 1.6, True),
    ("roomDamp", 0.0, 1.0, False),
    ("pitchDriftCents", 0.0, 8.0, False),
    ("pitchDriftRate", 0.05, 1.5, True),
]


# ---- Worker -----------------------------------------------------------------

def _init_worker():
    os.makedirs(WORK, exist_ok=True)


def evaluate(job):
    params, seed = job
    if not os.path.isdir(WORK):
        _init_worker()
    tag = f"{os.getpid()}_{time.monotonic_ns()}"
    spec_path = os.path.join(WORK, f"{tag}.json")
    wav_path = os.path.join(WORK, f"{tag}.wav")
    spec = {"durationSeconds": RENDER_SECONDS, "seed": seed,
            "params": params, "plucks": S.EVENTS, "out": wav_path}
    with open(spec_path, "w") as f:
        json.dump(spec, f)
    try:
        r = subprocess.run([RENDER_BIN, spec_path, "--mono"],
                           capture_output=True, text=True, timeout=120)
        if r.returncode != 0:
            return {"total": float("inf"), "components": {},
                    "error": r.stderr.strip()[:200]}
        return S.compute_loss(wav_path)
    except Exception as e:  # noqa: BLE001
        return {"total": float("inf"), "components": {}, "error": str(e)[:200]}
    finally:
        for p in (spec_path, wav_path):
            try:
                os.remove(p)
            except OSError:
                pass


# ---- Elites -----------------------------------------------------------------

class Elites:
    def __init__(self, cap=10):
        self.cap = cap
        self.items = []

    def offer(self, loss, params):
        if not np.isfinite(loss):
            return
        self.items.append((loss, json.loads(json.dumps(params))))
        self.items.sort(key=lambda t: t[0])
        del self.items[self.cap:]

    def materialize(self):
        shutil.rmtree(TOP, ignore_errors=True)
        os.makedirs(TOP, exist_ok=True)
        ref = S.load_ref()
        for rank, (loss, params) in enumerate(self.items):
            base = os.path.join(TOP, f"{rank:02d}_loss{loss:.2f}")
            tm.atomic_write_json(base + ".json", params)
            spec = {"durationSeconds": RENDER_SECONDS, "seed": RENDER_SEED,
                    "params": params, "plucks": S.EVENTS, "out": base + ".wav"}
            sp = base + "_spec.json"
            tm.atomic_write_json(sp, spec)
            subprocess.run([RENDER_BIN, sp], check=False)
            os.remove(sp)
            try:
                c = tm.load_wav_mono(base + ".wav")
                n = min(len(ref), len(c))
                ir = tm.logspec_image(ref[:n], fmin=120, fmax=12000)
                ic = tm.logspec_image(c[:n], fmin=120, fmax=12000)
                h = min(ir.shape[0], ic.shape[0])
                w = min(ir.shape[1], ic.shape[1])
                gap = np.full((4, w, 3), 255, np.uint8)
                tm.write_png(base + ".png",
                             np.vstack([ir[:h, :w], gap, ic[:h, :w]]))
            except Exception as e:  # noqa: BLE001
                print(f"  (png failed: {e})")


def log_trial(params, result):
    rec = {"loss": result.get("total"), "components": result.get("components"),
           "t": round(time.time(), 1),
           "dims": {p: round(float(get_path(params, p)), 6)
                    for (p, _lo, _hi, _lg) in DIMS
                    if get_path(params, p) is not None}}
    with open(TRIALS, "a") as f:
        f.write(json.dumps(rec) + "\n")


# ---- Run --------------------------------------------------------------------

def _z_of(params):
    def x0_z(p, lo, hi, lg):
        v = get_path(params, p)
        z = value_to_z(v if v is not None else (lo + hi) / 2, lo, hi, lg)
        if abs(z) >= 3.85:
            z = 1.73 if z > 0 else -1.73
        return z
    return np.array([x0_z(*d) for d in DIMS])


def _es_healthy(es):
    return (np.isfinite(es.m).all() and np.isfinite(es.sigma)
            and np.isfinite(es.C).all() and np.isfinite(es.pc).all()
            and np.isfinite(es.ps).all() and 1e-3 < es.sigma < 100)


SIGMA_CEIL = 1.2          # the borrowed CMA-ES overflows if sigma runs away
RESTART_EVERY = 45        # IPOP-style restart from the running best


def run(pool, base, gens, lam, elites, sigma0, seed):
    es = CMAES(_z_of(base), sigma0, lam, seed=seed)
    best = (float("inf"), base)
    since_restart = 0
    for g in range(gens):
        # Restart from the current best on a numerical blowup or on schedule
        # — caps covariance drift and re-centres the search where it's good.
        if not _es_healthy(es) or since_restart >= RESTART_EVERY:
            es = CMAES(_z_of(best[1]), sigma0, lam, seed=seed + g + 1)
            since_restart = 0
        try:
            zs = es.ask()
        except Exception:
            es = CMAES(_z_of(best[1]), sigma0, lam, seed=seed + g + 7)
            since_restart = 0
            zs = es.ask()
        cands = []
        for z in zs:
            cand = json.loads(json.dumps(base))
            for (p, lo, hi, lg), zi in zip(DIMS, z):
                set_path(cand, p, z_to_value(zi, lo, hi, lg))
            cands.append(cand)
        gseed = RENDER_SEED + g * 0x100  # alternate noise realization per gen
        results = pool.map(evaluate, [(c, gseed) for c in cands])
        fs = []
        for cand, res in zip(cands, results):
            f = res["total"]
            fs.append(f)
            log_trial(cand, res)
            elites.offer(f, cand)
            if f < best[0]:
                best = (f, cand)
                tm.atomic_write_json(S.BEST + ".partial", cand)
        with np.errstate(all="ignore"):
            es.tell(zs, fs)
        es.sigma = float(min(es.sigma, SIGMA_CEIL))
        since_restart += 1
        fin = [f for f in fs if np.isfinite(f)]
        comp = ""
        if fin:
            gi = int(np.argmin(fs))
            comp = " ".join(f"{k}={v:.2f}" for k, v in
                            results[gi]["components"].items())
        print(f"gen {g:3d}  best {best[0]:7.3f}  gmin "
              f"{min(fin) if fin else float('inf'):7.3f}  sigma {es.sigma:.3f}"
              f"  | {comp}", flush=True)
    return best


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--init", default=S.INIT)
    ap.add_argument("--gens", type=int, default=120)
    ap.add_argument("--lam", type=int, default=16)
    ap.add_argument("--workers", type=int, default=max(2, mp.cpu_count() - 2))
    ap.add_argument("--sigma", type=float, default=0.5)
    ap.add_argument("--seed", type=int, default=1234)
    args = ap.parse_args()

    os.makedirs(WORK, exist_ok=True)
    base = json.load(open(args.init))
    open(TRIALS, "w").close()
    elites = Elites(10)
    t0 = time.time()
    with mp.Pool(args.workers, initializer=_init_worker) as pool:
        loss, best = run(pool, base, args.gens, args.lam, elites, args.sigma,
                         args.seed)
    tm.atomic_write_json(S.BEST, best)
    elites.materialize()
    print(f"\ndone in {(time.time()-t0)/60:.1f} min  best loss {loss:.3f}")
    print(f"winner -> {S.BEST}")
    # cross-seed honesty check
    for sd in (RENDER_SEED, RENDER_SEED + 777):
        w = os.path.join(WORK, f"_xseed{sd}.wav")
        S.render(best, w, seed=sd)
        res = S.compute_loss(w)
        print(f"  seed {sd:#x}: total {res['total']:.3f} "
              f"specres {res['components']['specres']:.2f}")
        os.remove(w)


if __name__ == "__main__":
    main()
