#!/usr/bin/env python3
"""Iterate analyze → render → compare → refine until convergence.

Drops a candidate score into ``auditions/inbox/``, waits for the
TarabdaarMac audition runner to produce ``outputs/<name>.wav`` and the
``.done`` marker, then scores the candidate against the target. If the
loudness (RMS) is too low compared to target, bumps the tilt/strike
values and tries again. Bails after ``--max-passes`` or once the RMS
ratio is within ``--rms-tolerance``.

Usage:
    python3 tools/audition_iterate.py auditions/target.wav

Produces ``auditions/outputs/best.wav`` (the closest candidate) and
``auditions/best.json`` (its score).
"""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import time
from pathlib import Path

THIS_DIR = Path(__file__).resolve().parent
ANALYZE = THIS_DIR / "audition_analyze.py"
COMPARE = THIS_DIR / "audition_compare.py"

REPO = THIS_DIR.parent
INBOX = REPO / "auditions" / "inbox"
OUTPUTS = REPO / "auditions" / "outputs"


def run_score(name: str, score: dict, timeout_s: float = 30.0) -> Path:
    """Atomically drop a score into the inbox and wait for the renderer
    to produce a `.done` marker. Returns the rendered WAV path. Raises
    on `.error` or timeout.
    """
    INBOX.mkdir(parents=True, exist_ok=True)
    OUTPUTS.mkdir(parents=True, exist_ok=True)
    json_path = INBOX / f"{name}.json"
    done_path = INBOX / f"{name}.done"
    err_path = INBOX / f"{name}.error"
    wav_path = OUTPUTS / f"{name}.wav"
    # Clear previous run if present so we wait for THIS run's marker.
    for p in (json_path, done_path, err_path, wav_path):
        if p.exists():
            p.unlink()
    tmp = json_path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(score, indent=2) + "\n")
    tmp.rename(json_path)
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if done_path.exists():
            # Wait for the WAV's size to stabilize — the audition runner
            # writes the .done marker as soon as stopRecording returns,
            # but AVAudioFile may still be flushing its last buffers.
            return _wait_for_stable(wav_path)
        if err_path.exists():
            raise RuntimeError(f"renderer error: {err_path.read_text()}")
        time.sleep(0.25)
    raise TimeoutError(f"renderer did not finish within {timeout_s}s for {name}")


def _wait_for_stable(path: Path, attempts: int = 10, delay: float = 0.15) -> Path:
    prev = -1
    for _ in range(attempts):
        if not path.exists():
            time.sleep(delay)
            continue
        size = path.stat().st_size
        if size > 0 and size == prev:
            return path
        prev = size
        time.sleep(delay)
    return path


def metrics(target: Path, candidate: Path) -> dict:
    """Run audition_compare.py and parse its summary fields."""
    out = subprocess.run(
        [sys.executable, str(COMPARE), str(target), str(candidate)],
        capture_output=True, text=True, check=True,
    ).stdout
    res: dict = {}
    for line in out.splitlines():
        s = line.strip()
        if s.startswith("envelope L1 sum"):
            res["env_sum"] = float(s.split(":")[1])
        elif s.startswith("envelope L1 mean"):
            res["env_mean"] = float(s.split(":")[1])
        elif s.startswith("mean |Δsemitone|"):
            res["semi"] = float(s.split(":")[1])
        elif s.startswith("voiced windows"):
            tail = s.split(":")[1].strip()
            a, b = tail.split("/")
            res["voiced"] = int(a)
            res["windows"] = int(b)
    return res


def analyze_score(target: Path, name: str) -> dict:
    out = subprocess.run(
        [sys.executable, str(ANALYZE), str(target), "--name", name],
        capture_output=True, text=True, check=True,
    )
    score = json.loads(out.stdout)
    return score


def candidate_peak(wav: Path) -> int:
    """Mono peak amplitude of the rendered candidate. Used to scale
    the tilt/strike push between passes (target RMS / candidate RMS ≈
    how much louder we need to push).
    """
    import wave, struct
    with wave.open(str(wav)) as w:
        raw = w.readframes(w.getnframes())
        ch = w.getnchannels()
    samples = struct.unpack("<" + "h" * (len(raw) // 2), raw)
    mono = [(samples[i] + samples[i + 1]) // 2 for i in range(0, len(samples), ch)] if ch == 2 else list(samples)
    return max((abs(s) for s in mono), default=0)


def target_peak(wav: Path) -> int:
    return candidate_peak(wav)


def bump_amplitude(score: dict, factor: float) -> dict:
    """Multiply tilt and strike values by `factor`, clamping into
    valid ranges (tilt ∈ [-1, 1], strike ∈ [0.001, 0.5]).
    """
    out = json.loads(json.dumps(score))
    for ev in out["events"]:
        if ev["kind"] == "tilt" and ev.get("axis") == 0:
            v = ev["value"] * factor
            ev["value"] = round(max(-1.0, min(1.0, v)), 3)
        elif ev["kind"] == "strike":
            v = ev["value"] * factor
            ev["value"] = round(max(0.001, min(0.5, v)), 4)
    # If no strike event exists yet, insert one at t=0.
    if not any(ev["kind"] == "strike" for ev in out["events"]):
        out["events"].insert(0, {"at": 0.0, "kind": "strike",
                                 "value": round(min(0.5, 0.1 * factor), 4)})
    out["events"].sort(key=lambda e: (e["at"], 0 if e["kind"] == "tilt" else
                                              (1 if e["kind"] == "strike" else
                                              (2 if e["kind"] == "noteOff" else 3))))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("target", type=Path)
    ap.add_argument("--max-passes", type=int, default=6)
    ap.add_argument("--rms-tolerance", type=float, default=0.15,
                    help="Stop when candidate peak/target peak is within ±this fraction")
    args = ap.parse_args()

    target = args.target.resolve()
    if not target.exists():
        raise SystemExit(f"target not found: {target}")

    tgt_peak = target_peak(target)
    print(f"[target] peak={tgt_peak}", flush=True)

    best_score: dict | None = None
    best_wav: Path | None = None
    best_metrics: dict | None = None
    best_loss = float("inf")
    score = analyze_score(target, name="iter0")

    for p in range(args.max_passes):
        name = f"iter{p}"
        score["name"] = name
        print(f"\n[pass {p}] rendering {name}…", flush=True)
        wav = run_score(name, score)
        m = metrics(target, wav)
        peak = candidate_peak(wav)
        ratio = peak / max(1, tgt_peak)
        # Loss combines envelope distance and pitch error.
        loss = m.get("env_mean", 1e9) + 30 * m.get("semi", 0)
        print(f"[pass {p}] peak={peak} ratio={ratio:.2f} "
              f"env_mean={m.get('env_mean'):.1f} "
              f"semi={m.get('semi'):.2f} loss={loss:.1f}", flush=True)
        if loss < best_loss:
            best_loss = loss
            best_score = score
            best_wav = wav
            best_metrics = m
        if abs(ratio - 1.0) <= args.rms_tolerance:
            print(f"[pass {p}] within tolerance — stopping.", flush=True)
            break
        # Move toward target loudness: log-bias the factor so we don't
        # oscillate. Capped at 2.0 so a single bad pass can't push
        # tilt/strike off the rails.
        factor = (1.0 / max(0.3, ratio)) ** 0.6
        factor = max(0.5, min(2.0, factor))
        print(f"[pass {p}] bumping amplitude by ×{factor:.2f}", flush=True)
        score = bump_amplitude(score, factor)

    if best_score is None or best_wav is None:
        raise SystemExit("no successful pass")
    best_score_path = REPO / "auditions" / "best.json"
    best_wav_path = OUTPUTS / "best.wav"
    best_score_path.write_text(json.dumps(best_score, indent=2) + "\n")
    shutil.copy(best_wav, best_wav_path)
    print(f"\n[best] loss={best_loss:.1f}  metrics={best_metrics}")
    print(f"[best] score   -> {best_score_path}")
    print(f"[best] wav     -> {best_wav_path}")


if __name__ == "__main__":
    main()
