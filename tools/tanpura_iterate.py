#!/usr/bin/env python3
"""Autonomous tanpura parameter optimization against the reference.

Pipeline (all offline, no app needed):
  base params (measured_init.json from `tanpura_match.py fit-init`)
    -> Stage 0: 1-D sanity sweeps (CSV loss curves; catches flat metrics)
    -> Stage A: per-string law polish (CMA-ES on harm loss per string)
    -> Stage B: joint texture polish (CMA-ES on full loss; restart support)
  every eval logged to trials.jsonl; top candidates kept as WAV + params
  + ref-vs-candidate spectrogram PNG in auditions/tanpura/top/.

Each eval renders the measured reference pluck schedule through
`tanpura-render` (deterministic seed) and scores it with the same
pluck-synchronous per-harmonic measurement applied to the reference —
biases cancel, differences count.

Usage:
  python3 tools/tanpura_iterate.py                # full run
  python3 tools/tanpura_iterate.py --quick        # tiny smoke run
  python3 tools/tanpura_iterate.py --stage B      # only stage B
"""

import argparse
import json
import multiprocessing as mp
import os
import shutil
import subprocess
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tanpura_match as tm  # noqa: E402

REPO = tm.REPO
TDIR = tm.TDIR
RENDER_BIN = os.path.join(REPO, "Packages", "StarpadDSP", ".build", "release",
                          "tanpura-render")
WORK = os.path.join(TDIR, "work")
TOP = os.path.join(TDIR, "top")
TRIALS = os.path.join(TDIR, "trials.jsonl")
BEST = os.path.join(TDIR, "best_params.json")

RENDER_SECONDS = 32.0          # schedule slice rendered per eval
# Weight of the auxiliary-reference mean total against the main loss.
# Aux totals carry no harm term (their per-string matrices don't exist),
# so their scale is roughly specres-dominated; 1.2 makes the
# generalization set a near-equal partner.
AUX_WEIGHT = 1.2
#   (4,8): the exposed opening — strings entering one at a time right
#   after the recording's ~3.4 s fade-in; the first thing a listener
#   judges, previously unscored (review finding).
TEXTURE_WINDOWS = [(4.0, 8.0), (8.0, 18.0), (20.0, 30.0)]
RENDER_SEED = 4242             # fixed -> deterministic evals, no noise

# ---------------------------------------------------------------------------
# Parameter space. path uses tanpura_match-style dotted paths into the
# params dict; the pseudo-string "saPair" writes the same value to strings
# 1 and 2 (the unison pair is acoustically one voice). log=True optimizes
# in log space.

def string_dims(prefix):
    return [
        (f"{prefix}.falloff", 0.0, 3.0, False),
        (f"{prefix}.pluckPos", 0.03, 0.45, False),
        # Decay capped at 8 s: real tanpura strings ring 3–8 s. The old
        # 16 s ceiling (× runaway decay trims) let the optimizer build a
        # static drone bed that gamed the truncation-blind metrics.
        (f"{prefix}.decay", 0.3, 8.0, True),
        (f"{prefix}.dampTilt", 0.0, 1.6, False),
        (f"{prefix}.bloomDelay", 0.005, 1.0, True),
        (f"{prefix}.bloomSkew", 0.0, 1.8, False),
        (f"{prefix}.attackLevel", 0.0, 1.0, False),
        (f"{prefix}.attackDecay", 0.008, 0.3, True),
        (f"{prefix}.level", 0.1, 1.5, False),
    ]


GLOBAL_DIMS = [
    # Jiva caps tightened after run 13: a probe found the whole 8-string
    # wah vanishes at depth≤0.45, spread≤0.35, conserve≥0.7 (all strings'
    # 2.5-4 Hz pump ≤ the reference's 0.052) at ~0 specres cost. Bounding
    # the search there keeps the polish from wandering back into the wah
    # while it re-balances specres/generalization.
    ("jivaDepth", 0.0, 0.45, False),
    ("jivaRate", 0.08, 2.5, True),
    ("jivaTilt", 0.0, 1.0, False),
    # Energy-conserving jiva: redistribute between harmonics instead of
    # pumping the summed envelope (the "wah-wah" complaint on v6).
    ("jivaConserve", 0.7, 1.0, False),
    # Per-harmonic jiva-rate scatter width: low concentrates the
    # modulation at one rate (the reference's tight ~2 Hz pulse) instead
    # of the broadband 1.5–7 Hz smear (the wah). modspec rewards this.
    ("jivaRateSpread", 0.0, 0.35, False),
    ("pluckVariationDB", 0.0, 5.0, False),
    ("noiseLevel", 0.0, 0.8, False),
    ("noiseDecay", 0.003, 0.08, True),
    ("noiseFreq", 500.0, 7000.0, True),
    ("noiseQ", 0.4, 6.0, True),
    ("crossExcite", 0.0, 0.4, False),
    ("bodyDry", 0.1, 1.0, False),
    ("tiltDB", -10.0, 10.0, False),
    # masterGain is deliberately NOT optimized: the loss RMS-normalizes
    # every level-sensitive term, so gain's only observable effect is
    # limiter saturation — which run 2 promptly exploited. It is pinned
    # low during optimization and peak-normalized at bake time.
    # body0 floor at 90 Hz = the specres grid's fmin; lower would be an
    # invisible sub-grid boom (review finding).
    # Body Q to 300: a Q≈300 band at ~300 Hz rings ~0.3 s — the measured
    # body mode near 307 Hz (rises after EVERY string's pluck, off every
    # partial grid) needs a true ringing resonance, not coloration.
    ("body0.freq", 90.0, 180.0, True),
    ("body0.gain", 0.0, 1.4, False),
    ("body0.q", 1.0, 300.0, True),
    ("body1.freq", 150.0, 450.0, True),
    ("body1.gain", 0.0, 1.4, False),
    ("body1.q", 1.0, 300.0, True),
    ("body2.freq", 500.0, 1800.0, True),
    ("body2.gain", 0.0, 1.4, False),
    ("body2.q", 1.0, 300.0, True),
    ("string0.level", 0.1, 2.2, False),
    ("saPair.level", 0.1, 2.2, False),
    ("string3.level", 0.1, 2.2, False),
    # Per-string temporal laws join the final joint polish so the full
    # temporal loss gets the last word on decay behavior.
    ("string0.decay", 0.3, 8.0, True),
    ("string0.dampTilt", 0.0, 1.6, False),
    ("string0.bloomDelay", 0.005, 1.0, True),
    ("saPair.decay", 0.3, 8.0, True),
    ("saPair.dampTilt", 0.0, 1.6, False),
    ("saPair.bloomDelay", 0.005, 1.0, True),
    ("string3.decay", 0.3, 8.0, True),
    ("string3.dampTilt", 0.0, 1.6, False),
    ("string3.bloomDelay", 0.005, 1.0, True),
    # Run 6+ (specres) additions. The absolute-grid residual sees the HF
    # sheen, so the gain-law shape and partial-stretch now matter:
    ("string0.falloff", 0.0, 3.0, False),
    ("saPair.falloff", 0.0, 3.0, False),
    ("string3.falloff", 0.0, 3.0, False),
    ("string0.bloomSkew", 0.0, 1.8, False),
    ("saPair.bloomSkew", 0.0, 1.8, False),
    ("string3.bloomSkew", 0.0, 1.8, False),
    ("string0.attackLevel", 0.0, 1.0, False),
    ("saPair.attackLevel", 0.0, 1.0, False),
    ("string3.attackLevel", 0.0, 1.0, False),
    # Inharmonicity capped at 1.2e-4: beyond that the stretch detunes
    # upper partials clean off the harm heterodyne probe and across
    # specres bands — a knob for HIDING strings rather than tuning them
    # (review finding). The tune term polices what remains.
    ("string0.inharmonicity", 1e-6, 1.2e-4, True),
    ("saPair.inharmonicity", 1e-6, 1.2e-4, True),
    ("string3.inharmonicity", 1e-6, 1.2e-4, True),
    # Unison detune of the sa pair (cents between the two strings,
    # symmetric about the measured f0). Slow beating makes the pair's
    # shared bands undulate instead of standing still.
    ("saDetuneCents", 0.0, 14.0, False),
    # Half-integer (jawari period-2) partial bank level + its own falloff.
    # The reference has these at −7…−35 dBpk (sa·3.5 = 918 Hz among the
    # loudest components); run-6's four worst residual regions were all
    # half-integer slots. The sub bank dies off faster with k than the
    # integer bank — a shared falloff left Pa·1.5 12 dB short while
    # SA·3.5+ overshot (run-7 residual).
    ("string0.subLevelDB", -55.0, -3.0, False),
    ("saPair.subLevelDB", -55.0, -3.0, False),
    ("string3.subLevelDB", -55.0, -3.0, False),
    ("string0.subFalloff", 0.3, 3.5, False),
    ("saPair.subFalloff", 0.3, 3.5, False),
    ("string3.subFalloff", 0.3, 3.5, False),
    # Sub-bank knee: keeps the loud low half-integer partials without the
    # h≳8 leak a single power law forces (run-8: +11 dB at 4 kHz).
    ("string0.subKneeH", 2.0, 64.0, True),
    ("saPair.subKneeH", 2.0, 64.0, True),
    ("string3.subKneeH", 2.0, 64.0, True),
    # Group trim on gainTrimDB[32:] — lets CMA reach the 8–16 kHz trims.
    ("string0.hfTrimDB", -12.0, 12.0, False),
    ("saPair.hfTrimDB", -12.0, 12.0, False),
    ("string3.hfTrimDB", -12.0, 12.0, False),
    # Slow per-string pitch waver — visible to specres' std component.
    ("pitchDriftCents", 0.0, 14.0, False),
    ("pitchDriftRate", 0.02, 1.0, True),
    # Room (Schroeder, in-renderer): the reference's room is part of the
    # sound — run-9's diffuse plateau (specres ~6.8 with residual spread
    # over every band) was the dry render's signature.
    # Wet/damp caps widened after run 10 landed on both.
    ("roomWetDB", -40.0, -3.0, False),
    ("roomDecayS", 0.15, 2.5, True),
    ("roomDamp", 0.0, 0.98, False),
    ("roomPredelayMs", 0.5, 40.0, True),
]


# ---------------------------------------------------------------------------
# Params-dict plumbing

def get_path(params, path):
    head, _, field = path.partition(".")
    if field == "hfTrimDB":
        base = params.get("_hfTrimBase", {})
        i = _string_indices(head)[0]
        b = base.get(str(i))
        if b is None:
            return 0.0
        g = params["strings"][i]["gainTrimDB"]
        return float(np.mean(np.array(g[32:32 + len(b)]) - np.array(b)))
    if path == "saDetuneCents":
        s = params["strings"]
        return abs(1200.0 * np.log2((s[1]["f0"] + 1e-9) / (s[2]["f0"] + 1e-9)))
    head, _, field = path.partition(".")
    if not field:
        return params.get(path)
    if head == "saPair":
        return params["strings"][1].get(field)
    if head.startswith("string"):
        return params["strings"][int(head[6:])].get(field)
    if head.startswith("body"):
        return params["body"][int(head[4:])].get(field)
    return None


def _string_indices(head):
    if head == "saPair":
        return [1, 2]
    return [int(head[6:])]


def set_path(params, path, value):
    head, _, field = path.partition(".")
    if field == "hfTrimDB":
        # Group offset on gainTrimDB[32:] — the 8–16 kHz trims the
        # per-harmonic arrays own but CMA can't reach individually
        # (run-8: sa k≈40 region 12–16 dB short). Idempotent via a
        # stashed base copy, like _saF0Center.
        base = params.setdefault("_hfTrimBase", {})
        for i in _string_indices(head):
            g = params["strings"][i]["gainTrimDB"]
            b = base.setdefault(str(i), [float(v) for v in g[32:]])
            for j, bv in enumerate(b):
                g[32 + j] = float(np.clip(bv + value, -40.0, 18.0))
        return
    if path == "saDetuneCents":
        # Symmetric unison detune about the measured center (stashed on
        # first use so repeated sets stay idempotent; the renderer's
        # Codable decode ignores the extra key). Geometric mean so a
        # stripped stash on an already-detuned init re-derives the SAME
        # center instead of drifting sharp.
        s = params["strings"]
        c = params.setdefault("_saF0Center",
                              float(np.sqrt(s[1]["f0"] * s[2]["f0"])))
        params["strings"][1]["f0"] = c * 2 ** (+value / 2400.0)
        params["strings"][2]["f0"] = c * 2 ** (-value / 2400.0)
        return
    head, _, field = path.partition(".")
    if not field:
        params[path] = value
        return
    if head == "saPair":
        params["strings"][1][field] = value
        params["strings"][2][field] = value
        return
    if head.startswith("string"):
        params["strings"][int(head[6:])][field] = value
        return
    if head.startswith("body"):
        params["body"][int(head[4:])][field] = value
        return
    raise KeyError(path)


def default_params():
    out = subprocess.run([RENDER_BIN, "--print-defaults"],
                         capture_output=True, text=True, check=True)
    return json.loads(out.stdout)


def fill_params(base):
    """Merge a (possibly partial) params dict over the renderer defaults."""
    full = default_params()
    for k, v in base.items():
        if k == "strings":
            for i, s in enumerate(v[:4]):
                full["strings"][i].update(s)
        elif k == "body":
            for i, b in enumerate(v[:3]):
                full["body"][i].update(b)
        else:
            full[k] = v
    return full


# z in R <-> bounded param value
def z_to_value(z, lo, hi, log):
    s = 1.0 / (1.0 + np.exp(-z))
    if log:
        return float(np.exp(np.log(lo) + (np.log(hi) - np.log(lo)) * s))
    return float(lo + (hi - lo) * s)


def value_to_z(v, lo, hi, log):
    if log:
        s = (np.log(np.clip(v, lo, hi)) - np.log(lo)) / (np.log(hi) - np.log(lo))
    else:
        s = (np.clip(v, lo, hi) - lo) / (hi - lo)
    s = np.clip(s, 0.02, 0.98)
    return float(np.log(s / (1 - s)))


# ---------------------------------------------------------------------------
# Worker: render + loss

_G = {}


def _init_worker():
    _G["model"] = json.load(open(tm.REF_MODEL))
    _G["npz"] = dict(np.load(tm.REF_NPZ))
    # Same cutoff compute_loss uses to select scoring events (at+0.35 <
    # duration) — a stricter render cutoff would leave scored onsets that
    # were never rendered, biasing the harm stack low.
    _G["plucks"] = [
        {"at": e["at"], "string": e["string"], "velocity": e.get("velocity", 0.8)}
        for e in _G["model"]["events"] if e["at"] + 0.35 < RENDER_SECONDS
    ]
    # Auxiliary references (refs/<name>/): other tanpuras, other tonics,
    # sparser playing — the generalization set. Sorted for determinism.
    aux = []
    refs_dir = os.path.join(TDIR, "refs")
    if os.path.isdir(refs_dir):
        for name in sorted(os.listdir(refs_dir)):
            mp = os.path.join(refs_dir, name, "model.json")
            wp = os.path.join(refs_dir, name, "reference.wav")
            if not (os.path.exists(mp) and os.path.exists(wp)):
                continue
            m = json.load(open(mp))
            dur = m["duration"]
            windows = [(0.2, dur)] if dur <= 11.0 else \
                [(0.2, dur / 2), (dur / 2, dur - 0.05)]
            aux.append({"name": name, "wav": wp, "model": m,
                        "windows": windows, "dur": dur})
    _G["aux"] = aux


def tuned_params(params, f0s):
    """Copy of `params` retuned to an aux reference's measured f0s: the
    timbre is SHARED across references, the tuning is per-reference. The
    sa-pair detune (cents between strings 1/2) is preserved around the
    reference's own sa."""
    q = json.loads(json.dumps(params))
    det = get_path(params, "saDetuneCents") or 0.0
    q["strings"][0]["f0"] = f0s[0]
    sa = float(np.sqrt(f0s[1] * f0s[2]))
    q["strings"][1]["f0"] = sa * 2 ** (+det / 2400.0)
    q["strings"][2]["f0"] = sa * 2 ** (-det / 2400.0)
    q["strings"][3]["f0"] = f0s[3]
    q.pop("_saF0Center", None)
    return q


def evaluate(job):
    """job = (params_dict, mode[, seed]) ; mode = ('harm', filter) or 'full'.

    The seed defaults to RENDER_SEED but run_cma alternates it per
    generation: thousands of evals on ONE frozen noise realization let
    CMA-ES align that realization with the reference's (jiva phases,
    pluck jitter, beat phase) — loss gains that evaporate on any other
    seed (review finding). Per-generation alternation makes seed-fitting
    unrankable while keeping evals within a generation comparable."""
    params, mode = job[0], job[1]
    seed = job[2] if len(job) > 2 else RENDER_SEED
    if not _G:
        _init_worker()
    tag = f"{os.getpid()}_{time.monotonic_ns()}"
    spec_path = os.path.join(WORK, f"{tag}.json")
    wav_path = os.path.join(WORK, f"{tag}.wav")
    iso_spec_path = os.path.join(WORK, f"{tag}_iso.json")
    iso_wav_path = os.path.join(WORK, f"{tag}_iso.wav")
    spec = {"durationSeconds": RENDER_SECONDS, "seed": seed,
            "params": params, "plucks": _G["plucks"], "out": wav_path}
    with open(spec_path, "w") as f:
        json.dump(spec, f)
    # Isolated-pluck render for the ring-time loss: one pluck per string,
    # each decay fully observable. crossExcite is forced to 0 here — the
    # brackets bound the plucked string's OWN ring-out; with coupling on,
    # the other strings' sympathetic ringing dominates the tail and the
    # run-6 winner "violated" every bracket while its laws were fine.
    iso_params = dict(params)
    iso_params["crossExcite"] = 0.0
    iso_spec = {"durationSeconds": tm.ISO_DURATION, "seed": seed,
                "params": iso_params,
                "plucks": [{"at": t, "string": s, "velocity": 0.9}
                           for t, s in tm.ISO_PLUCKS],
                "out": iso_wav_path}
    with open(iso_spec_path, "w") as f:
        json.dump(iso_spec, f)
    # Auxiliary minibatch: the single-pluck sample (index 0, the wah-wah
    # anchor — it's also the cheapest) every eval, plus two rotating by
    # generation seed. The timbre params are shared; each aux render is
    # retuned to that reference's measured f0s.
    aux_jobs = []
    aux_paths = []
    if mode == "full" and _G["aux"]:
        n_aux = len(_G["aux"])
        picks = {0, (seed % n_aux), ((seed // n_aux) + seed) % n_aux}
        for ai in sorted(picks):
            ref = _G["aux"][ai]
            ap = tuned_params(params, ref["model"]["f0s"])
            sp = os.path.join(WORK, f"{tag}_aux{ai}.json")
            wp = os.path.join(WORK, f"{tag}_aux{ai}.wav")
            spec_a = {"durationSeconds": ref["dur"] + 0.6, "seed": seed,
                      "params": ap,
                      "plucks": ref["model"]["events"], "out": wp}
            with open(sp, "w") as f:
                json.dump(spec_a, f)
            aux_jobs.append((ref, wp))
            aux_paths.extend([sp, wp])

    try:
        r = subprocess.run([RENDER_BIN, spec_path, iso_spec_path, "--mono"]
                           + aux_paths[0::2],
                           capture_output=True, text=True, timeout=240)
        if r.returncode != 0:
            return {"total": float("inf"), "components": {},
                    "error": r.stderr.strip()[:300]}
        if mode == "full":
            out = tm.compute_loss(wav_path, _G["model"], _G["npz"],
                                  windows=TEXTURE_WINDOWS, harm=True,
                                  iso_path=iso_wav_path)
        else:
            # Per-string stages keep the harm filter but ALWAYS carry the
            # full-mix temporal terms (spec/pulse/ring): a string's decay
            # affects the whole texture, and leaving it unconstrained here
            # is exactly how the first run smeared.
            out = tm.compute_loss(wav_path, _G["model"], _G["npz"],
                                  windows=TEXTURE_WINDOWS, harm=True,
                                  strings_filter=mode[1],
                                  iso_path=iso_wav_path)
        if aux_jobs:
            aux_totals = []
            aux_comps = {}
            for ref, wp in aux_jobs:
                # Aux refs: mod is brittle there (quiet recordings put
                # their noise floor inside the band-envelope statistics,
                # and a few missed soft rolls skew it); the 50 dB floor
                # keeps recording hiss out of the specres weighting.
                ao = tm.compute_loss(wp, ref["model"], {},
                                     windows=ref["windows"], harm=False,
                                     ref_wav=ref["wav"],
                                     cache_ns=ref["name"], floor_db=50.0,
                                     weights_override={"mod": 0.0})
                aux_totals.append(ao["total"])
                for k, v in ao["components"].items():
                    aux_comps.setdefault(k, []).append(v)
            out["components"]["auxTotal"] = float(np.mean(aux_totals))
            for k, vs in aux_comps.items():
                out["components"][f"aux_{k}"] = float(np.mean(vs))
            out["total"] = float(out["total"]
                                 + AUX_WEIGHT * np.mean(aux_totals))
        return out
    except Exception as e:  # noqa: BLE001
        return {"total": float("inf"), "components": {}, "error": str(e)[:300]}
    finally:
        for p in [spec_path, wav_path, iso_spec_path, iso_wav_path] + aux_paths:
            try:
                os.remove(p)
            except OSError:
                pass


# ---------------------------------------------------------------------------
# Minimal CMA-ES (Hansen (mu/mu_w, lambda), rank-1 + rank-mu)

class CMAES:
    def __init__(self, x0, sigma, lam, seed=1234):
        self.n = len(x0)
        self.lam = lam
        self.mu = lam // 2
        w = np.log(self.mu + 0.5) - np.log(np.arange(1, self.mu + 1))
        self.w = w / w.sum()
        self.mueff = 1.0 / (self.w ** 2).sum()
        n, mueff = self.n, self.mueff
        self.cc = (4 + mueff / n) / (n + 4 + 2 * mueff / n)
        self.cs = (mueff + 2) / (n + mueff + 5)
        self.c1 = 2 / ((n + 1.3) ** 2 + mueff)
        self.cmu = min(1 - self.c1,
                       2 * (mueff - 2 + 1 / mueff) / ((n + 2) ** 2 + mueff))
        self.damps = 1 + 2 * max(0, np.sqrt((mueff - 1) / (n + 1)) - 1) + self.cs
        self.chiN = np.sqrt(n) * (1 - 1 / (4 * n) + 1 / (21 * n ** 2))
        self.m = np.array(x0, dtype=float)
        self.sigma = sigma
        self.C = np.eye(n)
        self.pc = np.zeros(n)
        self.ps = np.zeros(n)
        self.B = np.eye(n)
        self.D = np.ones(n)
        self.rng = np.random.default_rng(seed)
        self.gen = 0

    def ask(self):
        self._decompose()
        self.zs = self.rng.standard_normal((self.lam, self.n))
        ys = self.zs @ np.diag(self.D) @ self.B.T
        return self.m + self.sigma * ys

    def _decompose(self):
        if not np.all(np.isfinite(self.C)):
            self.C = np.eye(self.n)
            self.pc[:] = 0
            self.ps[:] = 0
        self.C = (self.C + self.C.T) / 2
        d, B = np.linalg.eigh(self.C)
        d = np.nan_to_num(d, nan=1e-12, posinf=1e12, neginf=1e-12)
        self.D = np.sqrt(np.clip(d, 1e-12, 1e12))
        self.B = np.nan_to_num(B)

    def tell(self, xs, fs):
        fs = np.asarray(fs, dtype=float)
        fin = np.isfinite(fs)
        if not fin.any():
            return
        fs = np.where(fin, fs, fs[fin].max() * 2 + 1e3)
        idx = np.argsort(fs)[: self.mu]
        sel = xs[idx]
        old_m = self.m.copy()
        self.m = self.w @ sel
        y = (self.m - old_m) / self.sigma
        Cinv_sqrt = self.B @ np.diag(1 / self.D) @ self.B.T
        self.ps = ((1 - self.cs) * self.ps +
                   np.sqrt(self.cs * (2 - self.cs) * self.mueff) * (Cinv_sqrt @ y))
        hsig = (np.linalg.norm(self.ps) /
                np.sqrt(1 - (1 - self.cs) ** (2 * (self.gen + 1))) / self.chiN
                < 1.4 + 2 / (self.n + 1))
        self.pc = ((1 - self.cc) * self.pc +
                   hsig * np.sqrt(self.cc * (2 - self.cc) * self.mueff) * y)
        artmp = (sel - old_m) / self.sigma
        self.C = ((1 - self.c1 - self.cmu) * self.C
                  + self.c1 * (np.outer(self.pc, self.pc)
                               + (not hsig) * self.cc * (2 - self.cc) * self.C)
                  + self.cmu * artmp.T @ np.diag(self.w) @ artmp)
        self.sigma *= np.exp(min(1.0, (self.cs / self.damps) *
                                 (np.linalg.norm(self.ps) / self.chiN - 1)))
        self.sigma = float(np.clip(self.sigma, 1e-3, 3.0))
        # Numerical safety: a degenerate covariance restarts as isotropic.
        if not np.all(np.isfinite(self.C)):
            self.C = np.eye(self.n)
            self.pc[:] = 0
            self.ps[:] = 0
        self.gen += 1


# ---------------------------------------------------------------------------
# Trials log + elites

def log_trial(stage, params, result):
    rec = {"stage": stage, "loss": result.get("total"),
           "components": result.get("components"), "t": round(time.time(), 1),
           # The searched values — without them trials.jsonl can't answer
           # "which knob walked where while the loss fell" post-mortems.
           "dims": {p: round(float(get_path(params, p)), 6)
                    for (p, _lo, _hi, _lg) in GLOBAL_DIMS
                    if get_path(params, p) is not None}}
    with open(TRIALS, "a") as f:
        f.write(json.dumps(rec) + "\n")


class Elites:
    def __init__(self, cap=10):
        self.cap = cap
        self.items = []  # (loss, params)

    def offer(self, loss, params):
        if not np.isfinite(loss):
            return
        self.items.append((loss, json.loads(json.dumps(params))))
        self.items.sort(key=lambda t: t[0])
        del self.items[self.cap:]

    def materialize(self, plucks):
        shutil.rmtree(TOP, ignore_errors=True)
        os.makedirs(TOP, exist_ok=True)
        for rank, (loss, params) in enumerate(self.items):
            base = os.path.join(TOP, f"{rank:02d}_loss{loss:.1f}")
            tm.atomic_write_json(base + ".json", params)
            spec = {"durationSeconds": RENDER_SECONDS, "seed": RENDER_SEED,
                    "params": params, "plucks": plucks, "out": base + ".wav"}
            sp = base + "_spec.json"
            tm.atomic_write_json(sp, spec)
            subprocess.run([RENDER_BIN, sp], check=False)
            os.remove(sp)
            try:
                img_ref = tm.logspec_image(
                    tm.load_wav_mono(tm.REF_WAV)[: int(RENDER_SECONDS * tm.SR)])
                img_c = tm.logspec_image(tm.load_wav_mono(base + ".wav"))
                h = min(img_ref.shape[0], img_c.shape[0])
                w = min(img_ref.shape[1], img_c.shape[1])
                gap = np.full((4, w, 3), 255, dtype=np.uint8)
                tm.write_png(base + ".png",
                             np.vstack([img_ref[:h, :w], gap, img_c[:h, :w]]))
            except Exception as e:  # noqa: BLE001
                print(f"  (spectrogram failed: {e})")


# ---------------------------------------------------------------------------
# Stages

def run_cma(pool, base_params, dims, mode, stage_name, gens, lam, elites,
            sigma0=0.6, seed=1234):
    def x0_z(p, lo, hi, lg):
        v = get_path(base_params, p)
        z = value_to_z(v if v is not None else (lo + hi) / 2, lo, hi, lg)
        # A base value at/under a bound lands on the sigmoid clip boundary
        # (|z|=3.89) where the dim is gradient-dead under any sane sigma —
        # the new run-6 dims (detune, bloomSkew) all started there (review
        # finding). Pull such dims to a responsive starting z instead.
        if abs(z) >= 3.85:
            z = 1.73 if z > 0 else -1.73
        return z
    x0 = np.array([x0_z(*d) for d in dims])
    es = CMAES(x0, sigma0, lam, seed=seed)
    best = (float("inf"), base_params)
    for g in range(gens):
        zs = es.ask()
        jobs = []
        cands = []
        for z in zs:
            cand = json.loads(json.dumps(base_params))
            for (p, lo, hi, lg), zi in zip(dims, z):
                set_path(cand, p, z_to_value(zi, lo, hi, lg))
            cands.append(cand)
            # Alternate the render seed per GENERATION (see evaluate):
            # within a generation candidates stay comparable, across
            # generations the noise realization keeps changing, so the
            # only way to keep winning is to match the reference's
            # statistics rather than one frozen texture draw.
            jobs.append((cand, mode, RENDER_SEED + g))
        results = pool.map(evaluate, jobs)
        fs = np.array([r.get("total", float("inf")) for r in results])
        es.tell(zs, fs)
        for cand, r in zip(cands, results):
            log_trial(stage_name, cand, r)
            if mode == "full":
                elites.offer(r.get("total", float("inf")), cand)
        fin = np.isfinite(fs)
        if not fin.any():
            err = next((r.get("error") for r in results if r.get("error")), "?")
            print(f"  [{stage_name}] gen {g+1}/{gens}  ALL EVALS FAILED: {err}",
                  flush=True)
            continue
        i = int(np.argmin(fs))
        if fs[i] < best[0]:
            best = (float(fs[i]), cands[i])
            # Crash-safe running winner for multi-hour runs.
            tm.atomic_write_json(BEST + ".partial", best[1])
        print(f"  [{stage_name}] gen {g+1}/{gens}  best {best[0]:.3f}  "
              f"gen-best {fs[i]:.3f}  med {np.median(fs[fin]):.3f}  "
              f"sigma {es.sigma:.3f}", flush=True)
    return best


def stage0(pool, base, elites):
    print("Stage 0: 1-D sanity sweeps")
    # The decay sweeps are the key sanity check after the smear failure:
    # the temporal metrics must NOT be flat in decay, and the minimum must
    # sit at a plausible ring time — not at the cap.
    sweeps = [
        ("string3.bloomDelay", np.geomspace(0.01, 0.7, 10), ("harm", {3})),
        ("string3.falloff", np.linspace(0.0, 2.5, 10), "full"),
        ("string3.decay", np.geomspace(0.4, 8, 10), "full"),
        ("saPair.decay", np.geomspace(0.4, 8, 10), "full"),
        ("saPair.level", np.linspace(0.2, 1.8, 10), "full"),
        ("saDetuneCents", np.linspace(0.0, 8.0, 9), "full"),
        ("jivaDepth", np.linspace(0.0, 0.9, 10), "full"),
    ]
    rows = ["param,value,loss"]
    for path, values, mode in sweeps:
        jobs = []
        for v in values:
            cand = json.loads(json.dumps(base))
            set_path(cand, path, float(v))
            jobs.append((cand, mode))
        results = pool.map(evaluate, jobs)
        losses = [r.get("total", float("inf")) for r in results]
        for v, l in zip(values, losses):
            rows.append(f"{path},{v:.4f},{l:.4f}")
        arr = np.array(losses)
        fin = np.isfinite(arr)
        if not fin.any():
            err = next((r.get("error") for r in results if r.get("error")), "?")
            print(f"  {path}: ALL EVALS FAILED: {err}")
            continue
        flat = (arr[fin].max() - arr[fin].min()) < 0.02 * arr[fin].mean()
        amin = values[int(np.nanargmin(np.where(fin, arr, np.nan)))]
        print(f"  {path}: min at {amin:.3f}, range "
              f"[{arr[fin].min():.2f}, {arr[fin].max():.2f}]"
              f"{'  ⚠ FLAT METRIC' if flat else ''}")
    tm.atomic_write(os.path.join(TDIR, "stage0.csv"), "\n".join(rows))


def stage_a(pool, base, gens, elites):
    print("Stage A: per-string law polish (harm loss)")
    cur = json.loads(json.dumps(base))
    for cls, prefix, flt in ((0, "string0", {0}), (1, "saPair", {1}), (3, "string3", {3})):
        dims = string_dims(prefix)
        print(f"  string class {prefix}")
        loss, best = run_cma(pool, cur, dims, ("harm", flt), f"A:{prefix}",
                             gens, lam=10, elites=elites, seed=100 + cls)
        cur = best
        tm.atomic_write_json(os.path.join(TDIR, f"stageA_{prefix}.json"), cur)
    return cur


def stage_b(pool, base, gens, elites, restarts=1):
    print("Stage B: joint texture polish (full loss)")
    best_overall = (float("inf"), base)
    starts = [(base, 0.5)]
    for r in range(restarts):
        starts.append((base, 0.9))  # wider re-exploration from same start
    for i, (start, sig) in enumerate(starts):
        loss, best = run_cma(pool, start, GLOBAL_DIMS, "full", f"B:{i}",
                             gens, lam=16, elites=elites, sigma0=sig,
                             seed=200 + i)
        if loss < best_overall[0]:
            best_overall = (loss, best)
    return best_overall


# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stage", default="all", choices=["all", "0", "A", "B"])
    ap.add_argument("--workers", type=int, default=max(2, min(8, os.cpu_count() - 2)))
    ap.add_argument("--gens-a", type=int, default=30)
    ap.add_argument("--gens-b", type=int, default=45)
    ap.add_argument("--restarts", type=int, default=1)
    ap.add_argument("--quick", action="store_true", help="tiny smoke run")
    ap.add_argument("--init", default=os.path.join(TDIR, "init_run6.json"))
    args = ap.parse_args()

    if args.quick:
        args.gens_a, args.gens_b, args.restarts = 3, 3, 0

    # ALWAYS rebuild (a no-op when fresh): a stale binary silently
    # truncates new-schema params — e.g. pre-64-harmonic builds clamp
    # harmonicCount and prefix-truncate trims, and every candidate renders
    # wrong with no error (review finding).
    print("building tanpura-render…")
    subprocess.run(["swift", "build", "-c", "release", "--package-path",
                    os.path.join(REPO, "Packages", "StarpadDSP")], check=True)
    os.makedirs(WORK, exist_ok=True)
    os.makedirs(TOP, exist_ok=True)

    base = fill_params(json.load(open(args.init)))
    # Schema handshake with the binary actually on disk.
    n_trim = len(default_params()["strings"][0]["gainTrimDB"])
    if base.get("harmonicCount") != n_trim:
        raise SystemExit(
            f"init harmonicCount {base.get('harmonicCount')} != renderer "
            f"maxHarmonics {n_trim} — wrong --init or stale tanpura-render")
    # Pin render gain well below the limiter knee for every candidate
    # (see the masterGain note in GLOBAL_DIMS). The clip loss term handles
    # whatever level-stacking still reaches the knee. 0.06 leaves headroom
    # for the 64-harmonic stack and levels up to 1.8.
    base["masterGain"] = 0.06
    elites = Elites()
    t0 = time.time()

    with mp.Pool(args.workers, initializer=_init_worker) as pool:
        # Baseline eval of the starting point.
        r = pool.map(evaluate, [(base, "full")])[0]
        print(f"start loss {r['total']:.3f}  {json.dumps({k: round(v, 2) for k, v in r['components'].items()})}")
        elites.offer(r["total"], base)
        log_trial("init", base, r)

        cur = base
        if args.stage in ("all", "0"):
            stage0(pool, cur, elites)
        if args.stage in ("all", "A"):
            cur = stage_a(pool, cur, args.gens_a, elites)
            r = pool.map(evaluate, [(cur, "full")])[0]
            print(f"after Stage A: full loss {r['total']:.3f}")
            elites.offer(r["total"], cur)
        if args.stage in ("all", "B"):
            # `--init` is the explicit start point for a B-only run (e.g.
            # resuming from a previous winner); no hidden stage-A fallback.
            loss, cur = stage_b(pool, cur, args.gens_b, elites,
                                restarts=args.restarts)
            print(f"after Stage B: full loss {loss:.3f}")

        if args.stage == "0":
            # Sweeps only — don't clobber best_params.json / top/ with the
            # unoptimized init (this bit run 6's setup once).
            print("stage 0 only: best_params.json/top/ left untouched")
            return
        _init_worker()  # plucks for elite materialization
        tm.atomic_write_json(BEST, cur)
        elites.materialize(_G["plucks"])

    print(f"done in {time.time()-t0:.0f}s")
    print(f"best params: {BEST}")
    print(f"top candidates (LISTEN TO THESE vs {tm.REF_WAV}): {TOP}/")


if __name__ == "__main__":
    main()
