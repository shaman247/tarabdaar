#!/usr/bin/env python3
"""Analyze a target WAV and emit a first-pass audition score JSON.

Strategy:
 1. Compute a short-hop (50ms) RMS envelope.
 2. Mark "voiced" windows as those with RMS above a threshold derived
    from the loudest window.
 3. Estimate per-window pitch via autocorrelation on a longer (100ms)
    window, restricted to voiced regions.
 4. Detect onsets — voiced windows where the RMS rises significantly
    above the recent local average (suggests a new attack rather than
    sym-pool tail).
 5. Between consecutive onsets, take the median pitch as the held note.
 6. Emit a score with noteOn at each onset, noteOff at the next onset
    (or at the final voiced-window decay), and a single tilt setting
    derived from the median voiced RMS.

Outputs the JSON to stdout (and to ``--out`` if provided).
"""
from __future__ import annotations

import argparse
import json
import statistics
import struct
import sys
import wave
from math import log2
from pathlib import Path
from typing import List, Tuple


def load_mono(path: Path) -> Tuple[int, List[int]]:
    with wave.open(str(path)) as w:
        ch = w.getnchannels()
        sr = w.getframerate()
        sw = w.getsampwidth()
        if sw != 2:
            raise SystemExit(f"{path}: expected 16-bit PCM, got {sw*8}-bit")
        raw = w.readframes(w.getnframes())
    samples = list(struct.unpack("<" + "h" * (len(raw) // 2), raw))
    if ch == 1:
        return sr, samples
    return sr, [(samples[i] + samples[i + 1]) // 2 for i in range(0, len(samples), ch)]


def rms_envelope(mono: List[int], sr: int, hop_ms: int) -> List[float]:
    hop = sr * hop_ms // 1000
    out: List[float] = []
    for i in range(0, len(mono) - hop, hop):
        chunk = mono[i:i + hop]
        out.append((sum(s * s for s in chunk) / len(chunk)) ** 0.5)
    return out


def autocorr_pitch(window: List[int], sr: int,
                   fmin: float = 80.0, fmax: float = 1000.0) -> float:
    rms = (sum(s * s for s in window) / len(window)) ** 0.5
    if rms < 60:
        return 0.0
    min_lag = max(1, int(sr / fmax))
    max_lag = min(len(window) - 1, int(sr / fmin))
    if max_lag <= min_lag:
        return 0.0
    mean = sum(window) / len(window)
    w = [s - mean for s in window]
    best_lag = 0
    best_score = -1e18
    for lag in range(min_lag, max_lag + 1):
        s = 0
        for i in range(len(w) - lag):
            s += w[i] * w[i + lag]
        if s > best_score:
            best_score = s
            best_lag = lag
    if best_score <= 0 or best_lag == 0:
        return 0.0
    return sr / best_lag


def hz_to_midi(hz: float) -> int:
    if hz <= 0:
        return 0
    return int(round(69.0 + 12.0 * log2(hz / 440.0)))


def windowed_pitches(mono: List[int], sr: int, win_ms: int, hop_ms: int) -> List[float]:
    """Compute pitch on a sliding `win_ms` window stepped by `hop_ms`."""
    win = sr * win_ms // 1000
    hop = sr * hop_ms // 1000
    out: List[float] = []
    i = 0
    while i + win <= len(mono):
        out.append(autocorr_pitch(mono[i:i + win], sr))
        i += hop
    return out


def detect_onsets(env: List[float], hop_ms: int) -> List[int]:
    """Onsets = prominent local maxima of the smoothed RMS envelope,
    backtracked to where the rise actually started.

    Why this shape: bowed-instrument vibrato and sym-pool tail wobble
    both register as sharp first-derivative blips on a raw envelope,
    so a derivative-peak detector either under-counts (with a strict
    threshold) or over-counts (with a loose one). Smoothing first
    (~150 ms) eliminates the small wobbles and leaves the actual
    attack-then-decay shape of each note; finding peaks with
    prominence > ~15 % of the global peak then matches the per-note
    structure directly. The backtrack to "rise start" gives the score
    a sensible noteOn time rather than the post-attack peak.
    """
    import numpy as np
    from scipy.signal import find_peaks
    if not env:
        return []
    n = len(env)
    arr = np.asarray(env, dtype=float)
    peak = float(arr.max())
    if peak <= 0:
        return []

    # Symmetric box smoothing — ~150 ms window kills vibrato wobble
    # without smearing real attacks (which are typically >100 ms wide).
    box = max(1, 150 // hop_ms)
    kernel = np.ones(box) / box
    smoothed = np.convolve(arr, kernel, mode="same")

    # Prominence: vertical distance from a peak to its highest
    # neighboring valley. 15 % of global peak rejects sym-tail wobbles
    # but keeps real per-note rises that dip between attacks.
    min_distance = max(1, 250 // hop_ms)
    peaks, props = find_peaks(
        smoothed,
        prominence=peak * 0.15,
        distance=min_distance,
        height=peak * 0.25,
    )

    onsets: List[int] = []
    for p in peaks.tolist():
        # Walk back from the peak to where smoothed drops below 60 % of
        # the peak's height — that's our best estimate of where the
        # bow first met the string.
        target_level = smoothed[p] * 0.6
        rise = p
        for j in range(p - 1, max(-1, p - min_distance), -1):
            if smoothed[j] < target_level:
                rise = j + 1
                break
            rise = j
        onsets.append(rise)
    return onsets


def pitch_at_onset(pitches: List[float], onset_i: int, hop_ms: int) -> float:
    """Modal pitch over the 250ms after `onset_i`, with sym-tail sub-
    octaves filtered out before the vote.

    The autocorrelator likes the sym pool's strong harmonic below the
    played voice; if the modal pitch comes in as F3 or G3, the true
    fundamental is almost always one octave higher. We drop any
    reading <= MIDI 55 (G3) and re-mode, falling back to the raw mode
    only if every reading in the window was sub-G3.
    """
    skip = max(0, 50 // hop_ms)
    span = max(2, 250 // hop_ms)
    lo = onset_i + skip
    hi = min(len(pitches), lo + span)
    vals = [p for p in pitches[lo:hi] if p > 0]
    if not vals:
        return 0.0
    midi_bins = [round(69.0 + 12.0 * log2(p / 440.0)) for p in vals]
    high = [m for m in midi_bins if m >= 56]
    pool = high if high else midi_bins
    counts: dict = {}
    for m in pool:
        counts[m] = counts.get(m, 0) + 1
    best = max(counts.items(), key=lambda kv: (kv[1], -abs(kv[0] - 65)))
    return 440.0 * (2 ** ((best[0] - 69) / 12.0))


def note_release_index(env: List[float], onset_i: int, next_onset_i: int,
                       hop_ms: int, decay_ratio: float = 0.4) -> int:
    """Find the index where the note should be released: when env drops
    below `decay_ratio` × the onset window's peak. Bounded between
    150ms and 600ms from the onset (real viola bow strokes), and never
    past the next onset.
    """
    min_dur = max(1, 150 // hop_ms)
    max_dur = max(min_dur + 1, 600 // hop_ms)
    end_limit = min(next_onset_i, onset_i + max_dur, len(env))
    peak = max(env[onset_i:onset_i + max_dur + 1] or [0])
    if peak <= 0:
        return min(onset_i + min_dur, end_limit)
    for j in range(onset_i + min_dur, end_limit):
        if env[j] < peak * decay_ratio:
            return j
    return end_limit


def median_pitch_in_range(pitches: List[float], lo: int, hi: int) -> float:
    """Median nonzero pitch over `[lo, hi)`."""
    vals = [p for p in pitches[lo:hi] if p > 0]
    if not vals:
        return 0.0
    return statistics.median(vals)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("wav", type=Path)
    ap.add_argument("--out", type=Path, default=None,
                    help="Write JSON score to this path (overwrites)")
    ap.add_argument("--hop-ms", type=int, default=50)
    ap.add_argument("--pitch-win-ms", type=int, default=120)
    ap.add_argument("--tail-seconds", type=float, default=1.5)
    ap.add_argument("--name", type=str, default="candidate")
    args = ap.parse_args()

    sr, mono = load_mono(args.wav)
    duration = len(mono) / sr
    env = rms_envelope(mono, sr, hop_ms=args.hop_ms)
    pitches = windowed_pitches(mono, sr, win_ms=args.pitch_win_ms, hop_ms=args.hop_ms)
    # Align lengths (pitches uses larger window, fewer frames).
    n = min(len(env), len(pitches))
    env = env[:n]
    pitches = pitches[:n]

    onsets = detect_onsets(env, args.hop_ms)
    if not onsets:
        sys.exit("no onsets detected — target may be silent?")

    # Build events. Each onset spans up to the next onset (or end of
    # last voiced window).
    voiced_thresh = max(env) * 0.10
    # Find the last voiced index for the trailing release.
    last_voiced = n - 1
    for i in range(n - 1, -1, -1):
        if env[i] >= voiced_thresh:
            last_voiced = i
            break

    events = []
    # tilt1 drives MPE aftertouch by default, which SWAM Viola maps to
    # loudness. Target peak RMS / a calibration constant (an empirical
    # full-scale equivalent for the candidate) ≈ how high tilt1 should
    # ride. Hand-tuned for the SWAM Viola preset; revisit if presets
    # land that don't have aftertouch=tilt1 in their default mapping.
    peak = max(env)
    full_scale_rms = 1500.0   # observed: candidate peak RMS ≈ 1500 at tilt=1.0
    tilt = min(1.0, max(0.05, peak / full_scale_rms))
    events.append({"at": 0.0, "kind": "tilt", "axis": 0, "value": round(tilt, 3)})

    notes = []
    for idx, on_i in enumerate(onsets):
        next_on = onsets[idx + 1] if idx + 1 < len(onsets) else last_voiced + 1
        # Release this note when the envelope decays past 40% of its
        # local peak — emulates a real bow lift rather than letting the
        # sym tail dictate "note duration".
        off_i = note_release_index(env, on_i, next_on, args.hop_ms)
        midi = hz_to_midi(pitch_at_onset(pitches, on_i, args.hop_ms))
        if midi == 0:
            continue
        # Octave-clamp into the SWAM viola playing range (C3..C6 / MIDI
        # 48..84). Sym pool sub-octaves and out-of-range outliers get
        # folded in here.
        while midi < 48:
            midi += 12
        while midi > 84:
            midi -= 12
        on_t = on_i * args.hop_ms / 1000.0
        off_t = off_i * args.hop_ms / 1000.0
        notes.append((on_t, off_t, midi, idx + 1))

    for on_t, _, midi, nid in notes:
        events.append({"at": round(on_t, 3), "kind": "noteOn",
                       "id": nid, "note": midi})
    for on_t, off_t, midi, nid in notes:
        events.append({"at": round(off_t, 3), "kind": "noteOff", "id": nid})

    events.sort(key=lambda e: (e["at"], 0 if e["kind"] == "tilt" else
                                       (1 if e["kind"] == "noteOff" else 2)))

    # tailSeconds is sized so the rendered file matches the target's
    # total duration exactly — the audition runner uses
    # `lastEventAt + tailSeconds` as the total length, so picking it as
    # `targetDuration - lastEventAt` produces a render of the same span.
    last_off = max(off_t for _, off_t, _, _ in notes)
    pad = max(0.3, duration - last_off)
    score = {"name": args.name, "tailSeconds": round(pad, 3), "events": events}

    text = json.dumps(score, indent=2)
    if args.out is not None:
        # Write to a sibling temp then rename — avoids the audition
        # watcher reading a half-written file.
        tmp = args.out.with_suffix(args.out.suffix + ".tmp")
        tmp.write_text(text + "\n")
        tmp.rename(args.out)
    print(text)
    # Summary on stderr so stdout is clean JSON.
    print(f"\n# target duration {duration:.2f}s, {len(onsets)} onsets, "
          f"{len(notes)} notes, tilt={tilt:.3f}", file=sys.stderr)
    for on_t, off_t, midi, _ in notes:
        nm = midi_name(midi)
        print(f"#   {on_t:5.2f}s..{off_t:5.2f}s  MIDI {midi:3d}  ({nm})",
              file=sys.stderr)


_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]


def midi_name(m: int) -> str:
    return f"{_NAMES[m % 12]}{m // 12 - 1}"


if __name__ == "__main__":
    main()
