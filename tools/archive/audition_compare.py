#!/usr/bin/env python3
"""Compare a rendered audition WAV to a target WAV.

Reports overall duration, per-channel RMS, a 100ms-window RMS-envelope L1
distance, and a coarse pitch trace (autocorrelation per 100ms hop, mono
mix). Used by the audition iteration loop to score a candidate render
against ``auditions/target.wav``.
"""
from __future__ import annotations

import struct
import sys
import wave
from pathlib import Path
from typing import List, Tuple


def load_wav(path: Path) -> Tuple[int, int, List[int]]:
    with wave.open(str(path)) as w:
        ch = w.getnchannels()
        sr = w.getframerate()
        sw = w.getsampwidth()
        if sw != 2:
            raise SystemExit(f"{path}: expected 16-bit PCM, got {sw*8}-bit")
        raw = w.readframes(w.getnframes())
    samples = list(struct.unpack("<" + "h" * (len(raw) // 2), raw))
    return sr, ch, samples


def to_mono(samples: List[int], ch: int) -> List[int]:
    if ch == 1:
        return samples
    return [(samples[i] + samples[i + 1]) // 2 for i in range(0, len(samples), ch)]


def windowed_rms(mono: List[int], sr: int, hop_ms: int = 100) -> List[float]:
    hop = sr * hop_ms // 1000
    out: List[float] = []
    for i in range(0, len(mono) - hop, hop):
        chunk = mono[i:i + hop]
        out.append((sum(s * s for s in chunk) / len(chunk)) ** 0.5)
    return out


def autocorr_pitch(window: List[int], sr: int,
                   fmin: float = 80.0, fmax: float = 1000.0) -> float:
    """Plain time-domain autocorrelation pitch estimate. Returns 0 when
    the window is too quiet or no clear period is found.
    """
    rms = (sum(s * s for s in window) / len(window)) ** 0.5
    if rms < 60:
        return 0.0
    min_lag = max(1, int(sr / fmax))
    max_lag = min(len(window) - 1, int(sr / fmin))
    if max_lag <= min_lag:
        return 0.0
    # Remove DC
    mean = sum(window) / len(window)
    w = [s - mean for s in window]
    best_lag = 0
    best_score = -1e18
    # Sweep; coarse search is fine for our 100ms windows.
    for lag in range(min_lag, max_lag + 1, 1):
        s = 0
        for i in range(len(w) - lag):
            s += w[i] * w[i + lag]
        if s > best_score:
            best_score = s
            best_lag = lag
    if best_score <= 0 or best_lag == 0:
        return 0.0
    return sr / best_lag


def hz_to_midi(hz: float) -> float:
    if hz <= 0:
        return 0.0
    from math import log2
    return 69.0 + 12.0 * log2(hz / 440.0)


def envelope_distance(a: List[float], b: List[float]) -> Tuple[float, float]:
    """L1 distance per window between two RMS envelopes after length
    alignment (truncate to min). Returns (sum, mean).
    """
    n = min(len(a), len(b))
    if n == 0:
        return (0.0, 0.0)
    diffs = [abs(a[i] - b[i]) for i in range(n)]
    return (sum(diffs), sum(diffs) / n)


def report(label: str, path: Path) -> dict:
    sr, ch, samples = load_wav(path)
    mono = to_mono(samples, ch)
    duration = len(mono) / sr
    peak = max((abs(s) for s in mono), default=0)
    rms = (sum(s * s for s in mono) / max(1, len(mono))) ** 0.5
    envelope = windowed_rms(mono, sr, hop_ms=100)
    # Pitch trace at 100ms hop
    hop = sr // 10
    pitches: List[float] = []
    for i in range(0, len(mono) - hop, hop):
        chunk = mono[i:i + hop]
        f = autocorr_pitch(chunk, sr)
        pitches.append(f)
    midi = [hz_to_midi(p) if p > 0 else 0.0 for p in pitches]
    print(f"\n=== {label}: {path.name} ===")
    print(f"  duration  : {duration:.2f}s  sr={sr}  ch={ch}")
    print(f"  peak      : {peak} ({peak/32767:.4f})")
    print(f"  rms       : {rms:.1f} ({rms/32767:.5f})")
    print(f"  RMS env (per 100ms):")
    print("    " + " ".join(f"{int(e):>5d}" for e in envelope))
    print(f"  pitch hz (per 100ms):")
    print("    " + " ".join(f"{int(p):>5d}" for p in pitches))
    print(f"  pitch midi (per 100ms):")
    print("    " + " ".join(f"{int(round(m)) if m > 0 else 0:>5d}" for m in midi))
    return {
        "duration": duration,
        "sr": sr,
        "peak": peak,
        "rms": rms,
        "envelope": envelope,
        "pitches": pitches,
        "midi": midi,
    }


def main():
    if len(sys.argv) < 2:
        print("usage: audition_compare.py <target.wav> [candidate.wav]")
        sys.exit(2)
    target_path = Path(sys.argv[1])
    target = report("TARGET", target_path)
    if len(sys.argv) >= 3:
        cand_path = Path(sys.argv[2])
        cand = report("CANDIDATE", cand_path)
        s, m = envelope_distance(target["envelope"], cand["envelope"])
        print(f"\n=== COMPARE ===")
        print(f"  envelope L1 sum  : {s:.1f}")
        print(f"  envelope L1 mean : {m:.1f}")
        # Coarse pitch overlap on overlapping windows
        n = min(len(target["midi"]), len(cand["midi"]))
        if n > 0:
            both = [
                (t, c) for t, c in zip(target["midi"][:n], cand["midi"][:n])
                if t > 0 and c > 0
            ]
            if both:
                semi_err = sum(abs(t - c) for t, c in both) / len(both)
                print(f"  voiced windows   : {len(both)}/{n}")
                print(f"  mean |Δsemitone| : {semi_err:.2f}")


if __name__ == "__main__":
    main()
