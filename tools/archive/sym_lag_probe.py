#!/usr/bin/env python3
"""Measure the sym halo's staccato BLEND vs pitch SELECTIVITY tradeoff.

A driven 2-pole resonator's ring time τ and bandwidth are linked (Q=π·f·τ):
- long τ  → narrow band → SELECTIVE, but the halo peaks ~τ after a staccato
            note and rings long → an "echo" / two peaks.
- short τ → wide band → blends (peak during the note), but washy (poor
            pitch selectivity).
A fast-release **duck** (a ceiling that follows the drive level) can cut the
post-note tail without widening the bands, recovering blend at a longer τ.

This probe drives a viola-like C3 into a chromatic tarab bank via `sym-render`
and reports, per config:
  STACCATO: symPk (ms, want ≤ note-end ≈ 100), 2ndRatio (post-note/ during, <1)
  SELECT:   related/unrelated spectral contrast when playing C3 (want ≫1)
  SUSTAIN:  present-during RMS, ring-out ms
It also simulates a duck in python (so the duck's value can be judged before
implementing it in Swift).

Usage: python3 tools/sym_lag_probe.py
"""

import json
import os
import subprocess

import numpy as np
from scipy.io import wavfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SYM_RENDER = os.path.join(REPO, "Packages", "StarpadDSP", ".build", "release", "sym-render")
WORK = os.path.join(REPO, "auditions", "sarangi", "work")
SR = 44100

C3 = 130.81
BANK = [round(C3 * 2 ** (i / 12.0), 3) for i in range(25)]   # C3..C5 chromatic
RELATED = [261.6, 392.4, 523.2]          # C4 (oct), G4 (12th), C5 (2 oct)
UNRELATED = [C3 * 2 ** (6 / 12), C3 * 2 ** (1 / 12), C3 * 2 ** (8 / 12)]  # F#3, C#3, G#3
ATTACK, RELEASE, TAIL = 0.008, 0.020, 1.6


def trapezoid(total, aN, hN, rN):
    e = np.zeros(total)
    for i in range(total):
        if i < aN: e[i] = i / max(1, aN)
        elif i < aN + hN: e[i] = 1.0
        elif i < aN + hN + rN: e[i] = max(0.0, 1 - (i - aN - hN) / max(1, rN))
    return e


def viola(f0, env):
    t = np.arange(len(env)) / SR
    amps = [0.2, 1.0, 0.8, 0.6, 0.5, 0.4, 0.33, 0.28]
    sig = sum(a * np.sin(2 * np.pi * f0 * k * t)
              for k, a in enumerate(amps, 1) if f0 * k < 0.45 * SR)
    return sig / (np.max(np.abs(sig)) + 1e-9) * 0.25 * env


def make_drive(f0, hold, name):
    total = int((ATTACK + hold + RELEASE + TAIL) * SR)
    sig = viola(f0, trapezoid(total, ATTACK * SR, hold * SR, RELEASE * SR))
    os.makedirs(WORK, exist_ok=True)
    path = os.path.join(WORK, f"{name}.wav")
    wavfile.write(path, SR, (sig * 32767).astype(np.int16))
    return path, sig


def render(params, drive_path, out):
    spec = {"driveWav": drive_path, "frequencies": BANK, "params": params,
            "out": os.path.join(WORK, out)}
    sp = os.path.join(WORK, "probe.spec.json")
    open(sp, "w").write(json.dumps(spec))
    r = subprocess.run([SYM_RENDER, sp, "--mono"], capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(f"sym-render failed: {r.stderr}")
    _, y = wavfile.read(spec["out"])
    return y.astype(float) / 32768


def env_rms(x, win_ms=20.0):
    win = int(win_ms / 1000 * SR); hop = win // 2
    ts, es = [], []
    for s in range(0, len(x) - win, hop):
        ts.append((s + win / 2) / SR); es.append(np.sqrt(np.mean(x[s:s + win] ** 2)))
    return np.array(ts), np.array(es)


def duck(sym, drive_sig, release_ms, gain=40.0):
    """Simulated bus duck: a fast follower of |drive| (attack 4 ms / release
    `release_ms`) used as a ceiling on the sym (sym ×= min(1, env·gain))."""
    n = min(len(sym), len(drive_sig))
    sym, d = sym[:n], np.abs(drive_sig[:n])
    aA = 1 - np.exp(-1 / (0.004 * SR))
    aR = 1 - np.exp(-1 / (release_ms / 1000 * SR))
    env = np.zeros(n); e = 0.0
    for i in range(n):
        a = aA if d[i] > e else aR
        e += a * (d[i] - e); env[i] = e
    return sym * np.minimum(1.0, env * gain)


def goertzel(x, f, t0, dur):
    i0 = int(t0 * SR); nn = min(len(x) - i0, int(dur * SR))
    w = 2 * np.pi * f / SR; c = 2 * np.cos(w); s1 = s2 = 0.0
    for i in range(i0, i0 + nn):
        s0 = x[i] + c * s1 - s2; s2 = s1; s1 = s0
    return np.sqrt(max(0.0, s1 * s1 + s2 * s2 - c * s1 * s2)) / nn


def staccato_metrics(sym, drive_sig, hold):
    note_end = ATTACK + hold + RELEASE
    ts, es = env_rms(sym)
    symPk = ts[int(np.argmax(es))]
    during = es[(ts >= ATTACK) & (ts <= note_end)]
    after = es[ts > note_end]
    ratio = (after.max() / during.mean()) if len(after) and during.mean() > 0 else 0
    return symPk, ratio


def selectivity(sym, hold):
    note_end = ATTACK + hold + RELEASE
    rel = np.mean([goertzel(sym, f, ATTACK, hold) for f in RELATED])
    unrel = np.mean([goertzel(sym, f, ATTACK, hold) for f in UNRELATED])
    return rel / (unrel + 1e-12)


def main():
    hold = 0.08
    dp_stac, ds_stac = make_drive(C3, hold, "stac")
    dp_sus, ds_sus = make_drive(C3, 1.0, "sus")
    print(f"drive: viola-like C3 ({C3:.0f} Hz); staccato hold {hold*1000:.0f} ms, note-end ≈ {(ATTACK+hold+RELEASE)*1000:.0f} ms")
    print("want: symPk ≤ ~110 ms (blend), 2ndRatio < 1 (no echo), contrast ≫ 1 (selective)\n")
    header = f"  {'config':26s} {'symPk':>7s} {'2ndRatio':>9s} {'contrast':>9s} {'susRMS':>8s}"
    print(header)
    for decay in [0.06, 0.10, 0.15, 0.20, 0.30]:
        params = {"symDecay": decay}
        sym = render(params, dp_stac, "halo_stac.wav")
        symPk, ratio = staccato_metrics(sym, ds_stac, hold)
        contrast = selectivity(render(params, dp_sus, "halo_sus.wav"), 1.0)
        _, es_sus = env_rms(render(params, dp_sus, "halo_sus.wav"))
        susRMS = es_sus[(np.arange(len(es_sus)) > len(es_sus) * 0.3)].mean()
        print(f"  decay {decay:<20.2f} {symPk*1000:6.0f}m {ratio:8.2f} {contrast:8.1f} {susRMS:8.3f}")

    print("\n  + simulated duck (release sweep) on the longer, SELECTIVE decays:")
    for decay in [0.15, 0.20, 0.30]:
        sym = render({"symDecay": decay}, dp_stac, "halo_stac.wav")
        for rel_ms in [40, 80, 150]:
            ds = duck(sym, ds_stac, rel_ms)
            symPk, ratio = staccato_metrics(ds, ds_stac, hold)
            print(f"  decay {decay:.2f} duck rel {rel_ms:3d}ms      {symPk*1000:6.0f}m {ratio:8.2f}"
                  f"   (selectivity from the un-ducked bands)")


if __name__ == "__main__":
    main()
