#!/usr/bin/env python3
"""Autonomous LIVE full-chain match of the sarangi (SWAM Viola + sym halo +
viola body EQ + master FX) to the bowed reference samples.

Unlike the tanpura/sitar fits (offline `*-render`), the sarangi's played
voice is SWAM Viola — a real-time-only hosted AU with no offline renderer.
So we close the loop through the LIVE app: each candidate is a self-contained
audition score (set every tuned `voiceParam`, mute the tanpura, send CC11 so
SWAM speaks, play the reference's note at its f0) dropped into
`auditions/inbox/`; the StarpadMac `AuditionRunner` renders the COMPLETE
post-FX mix to `auditions/outputs/<name>.wav`; we score that against the real
sample with the tanpura `specres` metric (+ a body-resonance lock term).
CMA-ES (the tanpura optimizer's core, no `cma` dep) tunes the sym macros +
viola EQ + balance/FX.

REQUIRES the StarpadMac app running on .swamViola with a LICENSED SWAM Viola
and the audition runner active. A smoke render guards against silent SWAM.

  # 0. one-time: build the per-sample reference models
  python3 tools/sarangi_match.py refs
  # 1. confirm SWAM is producing sound through the live app
  python3 tools/sarangi_iterate.py --smoke
  # 2. run the loop (real-time, serial — ~1–1.5 h at the defaults)
  python3 tools/sarangi_iterate.py --gens 25
  # 3. materialize the winner's A/B + overlays on all 8 refs
  python3 tools/sarangi_iterate.py --materialize auditions/sarangi/live_best.json

Winner  -> auditions/sarangi/live_best.json
Trials  -> auditions/sarangi/live_trials.jsonl
Top-10  -> auditions/sarangi/live_top/<rank>/{score.json,out.wav,overlay.png,ab.wav}
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time

import warnings
from math import gcd

import numpy as np
from scipy.io import wavfile
from scipy.signal import resample_poly, welch

# The CMA-ES core (tanpura_iterate) does eigendecompositions that transiently
# over/underflow on degenerate early covariances; they're guarded downstream
# by nan_to_num + the tell() finite-mask, so silence the cosmetic warnings.
np.seterr(all="ignore")

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import tanpura_match as tm                 # noqa: E402  specres + IO + PNG
import sarangi_match as sm                 # noqa: E402  refs layout
from tanpura_iterate import (              # noqa: E402  optimizer core
    CMAES, z_to_value, value_to_z)
from audition_iterate import run_score     # noqa: E402  live render bridge

REPO = sm.REPO
SDIR = sm.SDIR
REFS_DIR = sm.REFS_DIR
LIVE_BEST = os.path.join(SDIR, "live_best.json")
LIVE_PARTIAL = LIVE_BEST + ".partial"
TRIALS = os.path.join(SDIR, "live_trials.jsonl")
TOP = os.path.join(SDIR, "live_top")
WEIGHTS_FILE = os.path.join(SDIR, "loss_weights.json")
SR = tm.SR

# Minibatch roster. anchor is scored EVERY generation; one rotating primary
# joins it per generation (rotated by gen index) so a generation's candidates
# are all judged on the SAME refs (fair CMA-ES selection) while the timbre is
# forced to generalize across generations. Validation refs (the scale +
# multi-note phrases) are rescored on the elites only — too costly per-eval.
ANCHOR = "sarangi3"
ROTATING = ["sarangi2", "sarangi5", "sarangi6"]
VALIDATION = ["sarangi4", "sarangi7", "sarangi8"]

DEFAULT_WEIGHTS = {"specres": 1.0, "body": 1.5, "tune": 0.03, "flat": 0.15, "hf": 3.0,
                   # Clarity suite — penalize the candidate ONLY when its spectrum is
                   # MORE DIFFUSE than the reference (energy smeared between the
                   # harmonic bands). specres compares loud-cell band MEANS and is
                   # blind to inter-harmonic valley depth, so a reverb-smeared "violin"
                   # render scores fine; these terms are what make the loop pursue the
                   # sarangi's sharpness/clarity. See score_pair.
                   "hnr": 2.0,         # harmonic-to-noise / inter-harmonic valley depth (sharpness guard)
                   "contrast": 1.0,    # per-octave spectral peak-to-valley prominence (sharpness guard)
                   "wiener": 0.8,      # spectral flatness excess (guards TOO diffuse)
                   # Brightness + density MATCH (the iter-2 "still a violin" fix): the
                   # render came out too dark + too clean/sparse vs a real sarangi.
                   "centroid": 8.0,    # two-sided spectral-centroid (brightness) match
                   "density": 3.0,     # one-sided flatness-deficit (penalize TOO clean) — pairs with wiener
                   # EXPERIMENTAL. Main-string harmonic profile vs the decomposed
                   # g_h bow target (tools/sarangi_decompose.py `target`): pulls
                   # SWAM's bow toward the real sarangi's AVERAGE bow timbre over
                   # the loud bow-dominated harmonics, decontaminated from the halo
                   # specres conflates it with. Inert if gh_target.json is absent.
                   # Watch the `gh` component in the trial log on a live run and
                   # tune/zero this weight — single performances vary several dB
                   # around the pooled target, so keep it gentle. See
                   # docs/sarangi-decompose.md.
                   "gh": 1.5}

# SWAM Viola AU parameter identifiers (from hostedParameterDump). The bowing
# controls shape the viola's harmonics AT THE SOURCE — near-bridge bowing
# (Bow Position low) + firm Bow Pressure give the bright/edgy sarangi character
# that a post-AU EQ can't synthesize. The steady-performance set is pinned so
# renders are deterministic regardless of leftover AU state.
SW_BOW_PRESSURE = "1484578252"
SW_BOW_POSITION = "1013107514"
SW_BOW_NOISE = "574719741"
SW_STRING_RESON = "1958189775"
SW_VIB_DEPTH = "1044572362"
SW_VIB_RATE = "796119545"
SW_PLAY_MODE = "2008574934"
SW_GESTURE = "1884889441"
SW_KEEP_BOW = "143125754"
SW_MANUAL_BOW = "277296446"
SW_RAND_FINGER = "1210414604"
SW_RAND_BOW = "1621033190"
SW_IBC = "1145853786"
SW_VRAND_RATE = "1291775422"
SW_BOW_SENS = "191587727"
# SWAM's internal room/reverb/ambience/body — pinned OFF so SWAM runs DRY. A wet
# hall reverb fills the inter-harmonic valleys with diffuse energy (the "violin,
# not sarangi" defect); we handle body + room downstream, shared with the sym
# halo. String Resonance (below) is periodic/sharpening, so it stays a SEARCH dim.
SW_ROOM_SIM = "1099171302"     # Ambiente Room Simulator (bool)
SW_REVERB_MIX = "389880618"
SW_REVERB_TIME = "1349089215"
SW_EARLY_REFL = "1088641165"
SW_AMBIENCE = "345785969"
SW_ROOM_SIZE = "1068695671"
SW_INST_BODY = "58272484"

# Tuned search dims: (voiceParam name, lo, hi, log?). 21 dims.
#  - Level knobs (symCoupling/Drive/Volume) are PINNED, not searched: specres
#    loudness-normalizes the total, so halo level and voiceMix are collinear —
#    voiceMix alone carries the halo↔viola balance DOF.
#  - The DRY-SWAM restructure (2026-06): SWAM's internal room/reverb/body are
#    pinned OFF; the halo's own SymBodyFilter + SchroederRoom are BYPASSED
#    (symBodyDry=1, body gains=0, symRoomWetDB=-60 in `pinned`). So the sarangi
#    has ONE shared body (`violaBodyEQ` on the SWAM+halo sub-bus) and ONE shared
#    room (the master reverb). The halo's intrinsic spectrum is now purely its
#    resonator voicing (falloff/decay/dampTilt/inharm/partials); the
#    body lives in violaBody*, the post-room shaping in postEQ*.
# NB. `cc11` is not a voiceParam — it's SWAM's Expression (the bow's pp→ff
# dynamic, the PRIMARY timbre/brightness control). `cc11` is special-cased in
# build_score into the score's CC11 events.
DIMS = [
    # sym halo timbre — brightness + dense shimmer (the sarangi "sharpness")
    ("symHarmonicFalloff", 0.3, 3.0, False),        # lower = brighter halo
    ("symDecay", 0.05, 0.60, True),                 # longer = more sympathetic ring
    ("symDampingTilt", 0.0, 1.6, False),
    ("symInharmonicity", 1e-6, 3e-4, True),
    ("symPartialCount", 16.0, 64.0, False),         # more high modes = brighter
    # SWAM bowing — the SOURCE brightness
    ("cc11", 90.0, 127.0, False),
    ("swam." + SW_BOW_POSITION, 0.08, 0.50, False), # toward bridge = bright/edgy
    ("swam." + SW_BOW_PRESSURE, 0.4, 1.0, False),
    ("swam." + SW_BOW_NOISE, 0.0, 0.8, False),
    ("swam." + SW_STRING_RESON, 0.0, 0.8, False),   # periodic sympathetic ring (sharpens)
    # shared sarangi body EQ (SWAM + halo sub-bus) — presence + air
    ("violaBody2.gainDB", -2.0, 12.0, False),       # ~1.9 kHz presence (freq pinned)
    ("violaBody3.freq", 3000.0, 6000.0, True),      # air band
    ("violaBody3.gainDB", -2.0, 12.0, False),
    # harmonic exciter — regenerates the missing HF air + harmonic density (the
    # iter-2 fix for "too dark / too clean"). Drives off the bowed signal.
    ("symExciteMix", 0.0, 0.5, False),              # added level of generated harmonics
    ("symExciteDrive", 5.0, 100.0, True),           # shaper drive = harmonic richness
    ("symExciteCrossover", 1500.0, 5000.0, True),   # HP corner (only HF excited)
    # post-reverb shaper — final spectral envelope (other freqs/widths pinned)
    ("postEQ0.gainDB", -12.0, 4.0, False),          # ~350 Hz low-mid bloom (mostly cut)
    ("postEQ1.freq", 800.0, 3000.0, True),          # nasal formant ↔ presence (the ~1 kHz gap)
    ("postEQ1.gainDB", -3.0, 9.0, False),
    ("postEQ2.freq", 5000.0, 10000.0, True),        # air band center
    ("postEQ2.gainDB", -3.0, 12.0, False),          # air
    # balance / FX
    ("voiceMix", 0.40, 0.85, False),                # halo is now bright → more is OK
    ("reverbMix", 5.0, 45.0, False),                # the single shared room
]
CC11_DIM = "cc11"   # routed to CC11 events, not a voiceParam

SUSTAIN_CAP = 3.0      # s — bound the sustained note (specres needs only the
                       # steady state, and shorter notes mean faster renders).
NOTE_CAP = 3.5         # s — per-note cap in a multi-note phrase.
LEAD = 0.2             # s — SWAM needs CC11 + a beat before the note speaks.
TAIL = 1.0             # s — recording tail past the last event.


# ---------------------------------------------------------------------------
# Audio IO — the LIVE app records at the hardware device rate (often 48 kHz),
# but the reference samples (and the whole specres grid) are 44.1 kHz, so we
# resample every render to SR before scoring. References (already 44.1 k)
# pass through untouched.

def _frame_count(path):
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            _sr, x = wavfile.read(path)
        return len(x)
    except Exception:  # noqa: BLE001
        return 0


def wait_stable_wav(path, timeout=8.0, min_frames=15000):
    """The audition runner writes the `.done` marker as soon as stopRecording
    returns, but AVAudioFile keeps flushing buffers after that — so a read
    right after `.done` can see 0 frames. Wait until the frame count is
    non-trivial AND stable across two reads (or give up)."""
    deadline = time.time() + timeout
    prev = -1
    while time.time() < deadline:
        n = _frame_count(path)
        if n >= min_frames and n == prev:
            return True
        prev = n
        time.sleep(0.2)
    return _frame_count(path) >= min_frames


def hires_spec(x, fmin=100.0, fmax=9000.0, height=820, max_cols=2400,
               nperseg=8192, hop=512):
    """Higher-resolution log-frequency spectrogram than tm.logspec_image
    (which is shared with tanpura at nperseg=4096/hop=1024). Finer STFT
    (5.4 Hz/bin, ~11 ms hop) + a taller/wider image so harmonic detail and
    the bow texture are legible in the A/B overlays."""
    from scipy import signal as _sig
    f, _t, Z = _sig.stft(x, SR, nperseg=nperseg, noverlap=nperseg - hop)
    mag = 20.0 * np.log10(np.abs(Z) + 1e-9)
    rows = np.geomspace(fmin, fmax, height)
    idx = np.searchsorted(f, rows)
    img = mag[np.clip(idx, 0, len(f) - 1)]
    if img.shape[1] > max_cols:
        img = img[:, ::max(1, img.shape[1] // max_cols)]
    lo, hi = np.percentile(img, 5), np.percentile(img, 99.5)
    v = np.clip((img - lo) / max(hi - lo, 1e-9), 0, 1)
    return tm.colormap(v[::-1])   # low freq at bottom


def load_resampled(path, target=SR):
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")          # AVAudioFile non-data chunk
        sr, x = wavfile.read(path)
    if np.issubdtype(x.dtype, np.integer):
        x = x.astype(np.float64) / float(np.iinfo(x.dtype).max)
    else:
        x = x.astype(np.float64)
    if x.ndim > 1:
        x = x.mean(axis=1)
    if sr != target:
        g = gcd(int(sr), int(target))
        x = resample_poly(x, target // g, sr // g)
    return x


# ---------------------------------------------------------------------------
# Seed + pinned values

def load_seed():
    init = json.load(open(sm.INIT))
    s0 = init["strings"][0]
    body = init["body"]
    seed = {
        # Seeds tuned for the VIOLIN base (already bright) — moderate bow +
        # light EQ so the seed lands near the real centroid, not overshooting.
        "symHarmonicFalloff": 0.9,              # bright-ish halo
        "symDecay": 0.15,                       # longer ring → more shimmer
        "symDampingTilt": s0["dampTilt"],
        "symInharmonicity": max(1e-6, s0["inharmonicity"]),
        "symPartialCount": 40.0,
        "cc11": 116.0,
        "swam." + SW_BOW_POSITION: 0.30,        # moderate (violin is bright already)
        "swam." + SW_BOW_PRESSURE: 0.75,
        "swam." + SW_BOW_NOISE: 0.4,
        "swam." + SW_STRING_RESON: 0.4,         # periodic ring (now a search dim)
        "violaBody2.gainDB": 4.0,
        "violaBody3.freq": 4200.0,
        "violaBody3.gainDB": 3.0,
        "symExciteMix": 0.18,                   # exciter: regenerate HF air + density
        "symExciteDrive": 35.0,
        "symExciteCrossover": 2800.0,
        "postEQ0.gainDB": -1.0,                 # slight low-mid (reverb-bloom) cut
        "postEQ1.freq": 1100.0,                 # toward the ~1 kHz nasal formant
        "postEQ1.gainDB": 3.0,
        "postEQ2.freq": 7000.0,
        "postEQ2.gainDB": 4.0,                  # air
        "voiceMix": 0.60,
        "reverbMix": 18.0,
    }
    pinned = {
        "tanpuraGainDB": -24.0,                 # mute the drone
        "violaBodyEnabled": 1.0,
        "filterResonance": 0.0,
        "symCoupling": 0.8,                     # pinned halo gains (see DIMS note)
        "symDriveLevel": 3.0,
        "sympatheticVolume": 0.9,
        # Halo body filter + room BYPASSED — the shared violaBodyEQ is the body
        # and the master reverb is the room (the dry-SWAM restructure). The body
        # filter is neutral at dry=1 + tilt=0 + all band gains=0; the Schroeder
        # room is bypassed at ≤ -59.9 dB. (freqs/Qs kept but inert at gain 0.)
        "symBodyDry": 1.0, "symBodyTiltDB": 0.0,
        "symBody0.freq": body[0]["freq"], "symBody0.gain": 0.0, "symBody0.q": body[0]["q"],
        "symBody1.freq": body[1]["freq"], "symBody1.gain": 0.0, "symBody1.q": body[1]["q"],
        "symBody2.freq": 2450.0, "symBody2.gain": 0.0, "symBody2.q": body[2]["q"],
        "symRoomWetDB": -60.0,
        "violaBody0.freq": 300.0, "violaBody0.gainDB": 2.0,
        "violaBody1.freq": 650.0, "violaBody1.gainDB": -7.0,
        "violaBody2.freq": 1900.0,
        "violaBody3.widthOct": 1.8,
        # Post-reverb shaper engaged; freqs/widths pinned, gains/air-freq searched.
        "postReverbEnabled": 1.0,
        "postEQ0.freq": 350.0, "postEQ0.widthOct": 1.0,
        "postEQ1.widthOct": 1.0,    # postEQ1.freq is now a search dim (nasal↔presence)
        "postEQ2.widthOct": 1.2,
        # Halo PITCH modulation off (no vibrato/tremolo). The shimmer comes from
        # the different sympathetic strings beating against each other.
        "symPitchDrift": 0.0,
        "symAmpModDepth": 0.0,
        # SWAM steady performance: vibrato off + the least-expressive, most
        # stable bowing mode. Pinned every render for a deterministic AU state.
        "swam." + SW_VIB_DEPTH: 0.0,
        "swam." + SW_VIB_RATE: 0.0,
        "swam." + SW_PLAY_MODE: 0.0,
        "swam." + SW_GESTURE: 0.0,
        "swam." + SW_KEEP_BOW: 0.0,
        "swam." + SW_MANUAL_BOW: 0.0,
        "swam." + SW_RAND_FINGER: 0.5,
        "swam." + SW_RAND_BOW: 0.5,
        "swam." + SW_IBC: 0.7,
        "swam." + SW_VRAND_RATE: 0.3,
        "swam." + SW_BOW_SENS: 0.5,
        # DRY SWAM: internal room/reverb/ambience/body OFF (we own body + room
        # downstream, shared with the sym halo). Removes the diffuse reverb that
        # filled the inter-harmonic valleys. String Resonance is a SEARCH dim now.
        "swam." + SW_ROOM_SIM: 0.0,
        "swam." + SW_REVERB_MIX: 0.0,
        "swam." + SW_REVERB_TIME: 0.0,
        "swam." + SW_EARLY_REFL: 0.0,
        "swam." + SW_AMBIENCE: 0.0,
        "swam." + SW_ROOM_SIZE: 0.0,
        "swam." + SW_INST_BODY: 0.0,
    }
    return seed, pinned


def weights():
    w = dict(DEFAULT_WEIGHTS)
    if os.path.exists(WEIGHTS_FILE):
        try:
            w.update(json.load(open(WEIGHTS_FILE)))
        except Exception:  # noqa: BLE001
            pass
    return w


# ---------------------------------------------------------------------------
# Score authoring

def note_events(model, cc11=100.0):
    """The performance: a sustained note (primary/anchor) or a note sequence
    (scale / multi-note). `cc11` is SWAM's Expression (bow dynamic/brightness)
    held across the note. Returns (events, last_event_time)."""
    cc11 = int(round(max(0.0, min(127.0, cc11))))
    rel = max(0, int(round(cc11 * 0.3)))
    ev = []
    segs = model.get("segments") or []
    multi = model.get("role") == "validation" and len(segs) > 1
    # rawNote BYPASSES the NoteManager — no pitch-bend vibrato LFO, no glide,
    # no tilt-CC emission. The reference sarangi notes are near-steady; the
    # NoteManager's vibrato (sent as continuous pitch bend) was the ~10c wobble.
    ev.append({"at": 0.0, "kind": "cc", "cc": 11, "value": int(round(cc11 * 0.45))})
    ev.append({"at": 0.08, "kind": "cc", "cc": 11, "value": cc11})
    if not multi:
        dur = min(SUSTAIN_CAP, max(1.0, model["window"][1] - model["window"][0]))
        on = LEAD
        off = on + dur
        ev.append({"at": on, "kind": "rawNote", "id": 1, "note": model["midi"],
                   "value": 95})
        ev.append({"at": round(off, 3), "kind": "cc", "cc": 11, "value": rel})
        ev.append({"at": round(off + 0.1, 3), "kind": "rawNoteOff", "id": 1,
                   "note": model["midi"]})
        return ev, off + 0.1
    t0 = segs[0]["at"]
    last = LEAD
    for i, s in enumerate(segs):
        on = LEAD + (s["at"] - t0)
        off = on + min(NOTE_CAP, s["dur"])
        ch = (i % 15) + 1
        ev.append({"at": round(on, 3), "kind": "rawNote", "id": ch,
                   "note": s["midi"], "value": 95})
        ev.append({"at": round(off, 3), "kind": "rawNoteOff", "id": ch,
                   "note": s["midi"]})
        last = off
    ev.append({"at": round(last + 0.05, 3), "kind": "cc", "cc": 11, "value": rel})
    return ev, last + 0.05


def build_score(name, vals, pinned, model):
    merged = {**pinned, **vals}
    cc11 = merged.pop(CC11_DIM, 100.0)          # SWAM Expression, not a voiceParam
    notes, last = note_events(model, cc11=cc11)
    setters = []
    for k, v in merged.items():
        setters.append({"at": 0.0, "kind": "voiceParam", "param": k,
                        "value": round(float(v), 6)})
    events = setters + notes
    events.sort(key=lambda e: (e["at"], 0 if e["kind"] == "voiceParam" else 1))
    return {"name": name, "tailSeconds": TAIL, "events": events}, last + TAIL


# ---------------------------------------------------------------------------
# Scoring

def _env(x, hop=0.01, win=0.03):
    H, W = int(hop * SR), int(win * SR)
    return np.array([np.sqrt(np.mean(x[i:i + W] ** 2))
                     for i in range(0, max(1, len(x) - W), H)])


def steady(x, lead=0.30, tail=0.15, rel=0.2):
    """The voiced steady region: from `lead` after onset to `tail` before
    offset (onset/offset by an RMS-envelope threshold). Aligns the candidate
    and reference at the steady state regardless of absolute timing."""
    env = _env(x)
    if len(env) < 3 or env.max() < 1e-5:
        return x
    above = np.where(env > rel * env.max())[0]
    if len(above) < 2:
        return x
    on = (above[0] * 0.01 + lead)
    off = (above[-1] * 0.01 - tail)
    i0, i1 = int(on * SR), int(off * SR)
    return x[i0:i1] if i1 - i0 > int(0.2 * SR) else x


def _band_mask(lo, hi, bands=112, fmin=90.0, fmax=16000.0):
    edges = np.geomspace(fmin, fmax, bands + 1)
    centers = np.sqrt(edges[:-1] * edges[1:])
    return (centers >= lo) & (centers <= hi)


_BODY_MASK = None
_HF_MASK = None


def body_band_mask():
    global _BODY_MASK
    if _BODY_MASK is None:
        _BODY_MASK = _band_mask(2300.0, 2900.0)
    return _BODY_MASK


def hf_band_mask():
    # The 2–8 kHz "sharpness" region. Scored UNIFORMLY (not specres' loud-cell
    # weighting) so the model can't ignore it just because it's a small
    # fraction of total energy — that's exactly why earlier runs went dull.
    global _HF_MASK
    if _HF_MASK is None:
        _HF_MASK = _band_mask(2000.0, 8000.0)
    return _HF_MASK


# ---------------------------------------------------------------------------
# Clarity metrics — "diffuse/noisy-between-bands vs sharp/clear"
#
# The defect: our render has too much energy in the VALLEYS between the k·f0
# harmonics (bow noise + reverb diffusion + dense halo beating fill them in),
# so the spectrogram reads diffuse and the tone reads "violin", not "sarangi".
# specres (loud-cell-weighted band MEANS, ~5%-wide bands, 70 ms smear) cannot
# see valley depth, so it never penalizes this. These three terms do.
#
# All run on the loudness-normalized `steady()` signals score_pair already
# loads, on a 5.4 Hz-bin Welch PSD (fine enough to resolve the valleys, unlike
# the 112-band grid), and are ONE-SIDED: a candidate is penalized only where it
# is MORE diffuse than the reference — being sharper than the ref is free. So
# every term self-tests to ≈0 on ref-vs-ref (identical signal ⇒ identical PSD).

def _midi_hz(midi):
    return 440.0 * 2.0 ** ((float(midi) - 69.0) / 12.0)


_PSD_CACHE = {}   # ref-wav path -> (f, Pdb) on its steady region (deterministic)


def _hires_psd(x):
    """Welch PSD in dB (nperseg=8192 → 5.4 Hz bins), matching tm.log_band_ltas."""
    f, P = welch(x, SR, nperseg=8192, noverlap=4096)
    return f, 10.0 * np.log10(P + 1e-12)


def _ref_psd(path, x):
    v = _PSD_CACHE.get(path)
    if v is None:
        v = _hires_psd(x)
        _PSD_CACHE[path] = v
    return v


def _comb_energy(f, P, f0, kmax=8):
    e = 0.0
    for k in range(1, kmax + 1):
        j = int(np.searchsorted(f, k * f0))
        lo, hi = max(0, j - 2), min(len(f), j + 3)
        if hi > lo:
            e += P[lo:hi].max()
    return e


def _refine_f0(f, Pdb, f0_seed, span_cents=60.0):
    """Snap the harmonic comb to a signal's true partials: the f0 that maximizes
    summed peak energy at k·f0. Robust to SWAM tuning offsets / microtonal refs
    so valley depth is measured against each signal's OWN comb (a fair
    periodicity read, independent of absolute tuning — `tune`/`flat` score
    tuning). Two-pass (coarse ±span, then fine ±5 cents) so the result is
    seed-independent: any seed in the same basin converges to the same f0,
    keeping ref-vs-ref ≈ 0."""
    P = 10.0 ** (Pdb / 10.0)
    coarse = f0_seed * 2.0 ** (np.linspace(-span_cents, span_cents, 25) / 1200.0)
    c0 = max(coarse, key=lambda v: _comb_energy(f, P, v))
    fine = c0 * 2.0 ** (np.linspace(-5.0, 5.0, 41) / 1200.0)
    return float(max(fine, key=lambda v: _comb_energy(f, P, v)))


def _valley_depth(f, Pdb, f0, kmax=30, fmax=12000.0):
    """Per-harmonic peak-to-valley depth (dB). Peak = max PSD within ±30 cents
    of k·f0; valley = median PSD in the central 40% of the gap to the next
    harmonic ((k+0.3)..(k+0.7)·f0, safely clear of both flanking partials).
    Returns (depths, peaks) over the harmonics that fit below fmax."""
    depths, peaks = [], []
    for k in range(1, kmax + 1):
        fk = k * f0
        if fk > fmax:
            break
        pm = (f >= fk * 2.0 ** (-30.0 / 1200)) & (f <= fk * 2.0 ** (30.0 / 1200))
        vm = (f >= (k + 0.3) * f0) & (f <= (k + 0.7) * f0)
        if not pm.any() or not vm.any():
            continue
        depths.append(float(Pdb[pm].max() - np.median(Pdb[vm])))
        peaks.append(float(Pdb[pm].max()))
    return np.array(depths), np.array(peaks)


def _hnr_shortfall(f, Pr, Pc, f0r, f0c):
    """Headline clarity term: how much SHALLOWER the candidate's inter-harmonic
    valleys are than the reference's, averaged over harmonics, weighted by the
    reference's per-harmonic loudness (loud harmonics dominate perception, like
    specres' loud-cell weighting)."""
    dr, pr = _valley_depth(f, Pr, f0r)
    dc, _ = _valley_depth(f, Pc, f0c)
    n = min(len(dr), len(dc))
    if n == 0:
        return 0.0
    dr, dc, pr = dr[:n], dc[:n], pr[:n]
    wk = np.clip((pr - (pr.max() - 40.0)) / 40.0, 0.0, 1.0)
    short = np.maximum(0.0, dr - dc)            # cand valley shallower → diffuse
    return float(np.sum(wk * short) / (np.sum(wk) + 1e-9))


_WIENER_BANDS = [(300.0, 1200.0), (1200.0, 3500.0), (3500.0, 8000.0)]


def _wiener_excess(f, Pr, Pc):
    """Spectral flatness (geometric/arithmetic mean of power) excess per band.
    A line spectrum (sharp) is peaky → low flatness; a noise-filled spectrum
    (diffuse) → high flatness. One-sided: penalize cand flatter than ref."""
    Pr_l, Pc_l = 10.0 ** (Pr / 10.0), 10.0 ** (Pc / 10.0)
    tot = 0.0
    for lo, hi in _WIENER_BANDS:
        m = (f >= lo) & (f <= hi)
        if m.sum() < 4:
            continue
        fr = np.exp(np.mean(np.log(Pr_l[m] + 1e-20))) / (np.mean(Pr_l[m]) + 1e-20)
        fc = np.exp(np.mean(np.log(Pc_l[m] + 1e-20))) / (np.mean(Pc_l[m]) + 1e-20)
        tot += max(0.0, fc - fr)
    return float(tot)


def _contrast_shortfall(f, Pr, Pc, n_oct=6, fmin=200.0, fmax=12000.0, q=0.2):
    """Per-octave spectral contrast = mean(top q-quantile dB) − mean(bottom
    q-quantile dB). Sharp = tall peaks over deep valleys (high contrast). Robust
    where the exact comb runs out (high k / inharmonicity). One-sided +
    ref-loudness-weighted, like _hnr_shortfall."""
    edges = np.geomspace(fmin, fmax, n_oct + 1)
    sw, num = 0.0, 0.0
    gpk = Pr.max() if len(Pr) else 0.0
    for i in range(n_oct):
        m = (f >= edges[i]) & (f < edges[i + 1])
        if m.sum() < 5:
            continue
        br, bc = np.sort(Pr[m]), np.sort(Pc[m])
        kq = max(1, int(q * len(br)))
        cr = br[-kq:].mean() - br[:kq].mean()
        cc = bc[-kq:].mean() - bc[:kq].mean()
        wk = float(np.clip((br[-kq:].mean() - (gpk - 40.0)) / 40.0, 0.0, 1.0))
        sw += wk * max(0.0, cr - cc)
        num += wk
    return float(sw / (num + 1e-9))


def _centroid_dist(f, Pr, Pc):
    """|octave distance| between the candidate's and reference's spectral
    centroids. TWO-SIDED: penalizes the candidate being too DARK *or* too
    bright. After the dry-SWAM + one-sided-clarity pass the render came out
    consistently too dark (centroid ~920 vs the sarangi's ~1170 Hz) — this term,
    paired with the exciter that can finally deliver HF, pulls brightness to
    MATCH the reference instead of just chasing a one-sided HF bound."""
    def cen(P):
        w = 10.0 ** (P / 10.0) * (f > 80)
        return float(np.sum(f * w) / (np.sum(w) + 1e-12))
    return float(abs(np.log2((cen(Pc) + 1e-9) / (cen(Pr) + 1e-9))))


def _density_deficit(f, Pr, Pc):
    """How much LESS dense (peakier/sparser) the candidate is than the reference,
    as a per-band log-flatness shortfall. A real sarangi is 5–7× denser (more
    sympathetic partials + bow grain + jawari buzz packing the spectrum); the
    clean dry render undershoots that. One-sided (only penalizes too-clean — the
    `wiener` term guards the other direction), so together they MATCH the ref's
    density. Density is added via the legit correlated sources (halo/buzz/
    exciter), not reverb (SWAM is dry)."""
    Pr_l, Pc_l = 10.0 ** (Pr / 10.0), 10.0 ** (Pc / 10.0)
    tot = 0.0
    for lo, hi in _WIENER_BANDS:
        m = (f >= lo) & (f <= hi)
        if m.sum() < 4:
            continue
        fr = np.exp(np.mean(np.log(Pr_l[m] + 1e-20))) / (np.mean(Pr_l[m]) + 1e-20)
        fc = np.exp(np.mean(np.log(Pc_l[m] + 1e-20))) / (np.mean(Pc_l[m]) + 1e-20)
        tot += max(0.0, float(np.log10((fr + 1e-9) / (fc + 1e-9))))
    return tot


# --- main-string harmonic-profile target (decontaminated from the halo) ------
# tools/sarangi_decompose.py isolates the real sarangi's MAIN bowed-string
# harmonic profile g_h (pitch-invariant, cross-raga-validated to ~0.5 dB) from
# the sympathetic halo and body. specres scores the FULL recording, so the bow
# timbre is conflated with the tarab shimmer; this term targets the bow source
# DIRECTLY. The bow dominates its own harmonics (~95 % of the energy at h·f0),
# so measuring the candidate's comb at h·f0 reads its main string with little
# halo contamination. Optional: silently inert if gh_target.json is absent.
GH_TARGET_FILE = os.path.join(REPO, "auditions", "sarangi", "gh_target.json")
_GH_TARGET = None


def gh_target():
    """(g_h dB source, log body grid, body dB) — empty if no target file."""
    global _GH_TARGET
    if _GH_TARGET is None:
        try:
            d = json.load(open(GH_TARGET_FILE))
            _GH_TARGET = (np.array(d["g_main_db"], float),
                          np.log(np.array(d["body_grid_hz"], float)),
                          np.array(d["body_db"], float))
        except Exception:  # noqa: BLE001
            _GH_TARGET = (np.zeros(0), np.zeros(0), np.zeros(0))
    return _GH_TARGET


def _gh_shortfall(c, f0):
    """Weighted |ΔdB| between the candidate's harmonic profile (at h·f0) and the
    g_h bow target RADIATED to this pitch — target[h] = g_h[h] + B(h·f0) − B(f0),
    so the real body's formants (e.g. ~2.6 kHz) are accounted for and the term
    purely drives SWAM's bow SOURCE falloff toward the real sarangi's. Weighted
    by target loudness over the loud harmonics."""
    tg, lbg, bdb = gh_target()
    if len(tg) < 4 or f0 <= 0:
        return 0.0
    amp = np.median(tm.measure_envelope_matrix(c, f0, n_harm=len(tg)), axis=1)
    if amp[0] <= 1e-9:
        return 0.0
    cdb = 20.0 * np.log10(np.maximum(amp, 1e-9) / amp[0])
    b0 = float(np.interp(np.log(f0), lbg, bdb)) if len(lbg) else 0.0
    num = den = 0.0
    for h in range(len(tg)):
        fh = (h + 1) * f0
        # only the LOUD, bow-dominated harmonics: above ~-18 dB the bowed string
        # is ~95 % of the comb (decomposition finding); weaker harmonics are
        # halo-contaminated (tarab collisions) and too noisy to target.
        if tg[h] < -18.0 or fh > 10000.0:
            continue
        bh = float(np.interp(np.log(fh), lbg, bdb)) if len(lbg) else 0.0
        target = tg[h] + (bh - b0)             # radiate the source through B
        wt = 10.0 ** (tg[h] / 20.0)            # weight by target loudness
        num += wt * abs(cdb[h] - target)
        den += wt
    return float(num / (den + 1e-12))


def clarity_panel(r, c, model, width, height=200):
    """A diagnostic strip stacked under the ref/cand spectrograms: per-harmonic
    inter-harmonic VALLEY DEPTH, reference (gray, left half of each slot) vs
    candidate (right half). Taller = deeper valleys = sharper/clearer. A
    candidate bar shaded ORANGE is SHALLOWER than the reference there (more
    diffuse — energy filling the gap), which is exactly the "violin not sarangi"
    defect. This is the perceptual-verification artifact the ear cross-checks."""
    img = np.full((height, width, 3), 18, np.uint8)
    try:
        fr, Pr = _hires_psd(r)
        _, Pc = _hires_psd(c)
        f0r = _refine_f0(fr, Pr, float(model.get("f0") or _midi_hz(model["midi"])))
        f0c = _refine_f0(fr, Pc, _midi_hz(model.get("midi"))
                         if model.get("midi") is not None else f0r)
        dr, _pr = _valley_depth(fr, Pr, f0r)
        dc, _pc = _valley_depth(fr, Pc, f0c)
    except Exception:  # noqa: BLE001
        return img
    n = int(min(len(dr), len(dc), 28))
    if n == 0:
        return img
    dr, dc = dr[:n], dc[:n]
    maxd = max(6.0, float(max(dr.max(), dc.max())))
    pad, base_y = 12, height - 12
    usable = height - 2 * pad
    slot = width / n
    for k in range(n):
        x0, x1 = int(k * slot), int((k + 1) * slot)
        mid = (x0 + x1) // 2
        hr = int(usable * min(1.0, dr[k] / maxd))
        img[base_y - hr:base_y, x0 + 1:mid, :] = (150, 150, 150)        # ref
        hc = int(usable * min(1.0, dc[k] / maxd))
        col = (80, 200, 220) if dc[k] >= dr[k] - 0.5 else (235, 120, 40)  # cyan ok / orange diffuse
        img[base_y - hc:base_y, mid:max(mid + 1, x1 - 1), :] = col
    return img


def score_pair(ref_wav, cand_wav, w, model):
    """specres + body-resonance lock + tune guard + clarity suite. Lower is
    better. `model` supplies the per-ref f0/midi for the harmonic-comb metrics."""
    try:
        r = steady(load_resampled(ref_wav))
        c = steady(load_resampled(cand_wav))
    except Exception:  # noqa: BLE001
        return float("inf"), {}
    if len(c) < int(0.3 * SR) or len(r) < int(0.3 * SR):
        return float("inf"), {"reason": "too-short/silent"}
    A, B, wt = tm.specres_grids(r, c)
    res = tm.specres_eval(A, B, wt)
    m = body_band_mask()
    body = float(abs(A[m].mean() - B[m].mean()))
    tune = float(tm.tune_error(r, c))
    # Pitch-steadiness: penalize the candidate's f0 wobble (cents std) above
    # the reference's. The bowed sarangi samples are near-steady; SWAM's
    # bowing FM reads as machine-vibrato. Prefers steadier bowing configs.
    flat = max(0.0, _wobble(c) - _wobble(r))
    # HF "sharpness": uniform per-band |ΔdB| in 2–8 kHz. A real sarangi's
    # penetrating edge lives here; the model is ~half as bright and specres'
    # loudness weighting all but ignores it (it's a tiny energy fraction), so
    # this term is what makes the loop actually pursue the sarangi sharpness.
    hm = hf_band_mask()
    hf = float(np.abs(A[hm] - B[hm]).mean())
    # Clarity suite (inter-harmonic valley depth / flatness / contrast). The
    # high-res PSD resolves the valleys the 112-band grid smears over.
    fr, Pr = _ref_psd(ref_wav, r)
    _fc, Pc = _hires_psd(c)
    wiener = _wiener_excess(fr, Pr, Pc)
    contrast = _contrast_shortfall(fr, Pr, Pc)
    # Brightness + density MATCH (two-sided centroid, one-sided density-deficit).
    # These attack the residual "still a violin" gap: the render is too dark and
    # too clean/sparse vs a real sarangi. Paired with the exciter (HF) + the
    # halo/buzz density, they pull the texture toward the reference.
    centroid = _centroid_dist(fr, Pr, Pc)
    density = _density_deficit(fr, Pr, Pc)
    # HNR needs a single f0 comb → meaningful only for a sustained single note.
    # Multi-note validation refs span several pitches; skip HNR there (wiener +
    # contrast are f0-free and still apply). Selection is driven by the
    # single-note anchor + rotating primaries anyway.
    multi = model.get("role") == "validation" and len(model.get("segments") or []) > 1
    if multi:
        hnr = gh = 0.0
    else:
        f0r = _refine_f0(fr, Pr, float(model.get("f0") or _midi_hz(model["midi"])))
        f0c = _refine_f0(fr, Pc, _midi_hz(model.get("midi"))
                         if model.get("midi") is not None else f0r)
        hnr = _hnr_shortfall(fr, Pr, Pc, f0r, f0c)
        gh = _gh_shortfall(c, f0c)            # main-string timbre vs g_h target
    total = (w["specres"] * res["total"] + w["body"] * body
             + w["tune"] * tune + w["flat"] * flat + w["hf"] * hf
             + w["hnr"] * hnr + w["contrast"] * contrast + w["wiener"] * wiener
             + w["centroid"] * centroid + w["density"] * density
             + w.get("gh", 0.0) * gh)
    return total, {"specres": round(res["total"], 3), "slow": round(res["slow"], 3),
                   "std": round(res["std"], 3), "body": round(body, 3),
                   "tune": round(tune, 2), "flat": round(flat, 2), "hf": round(hf, 3),
                   "hnr": round(hnr, 3), "contrast": round(contrast, 3),
                   "wiener": round(wiener, 4), "centroid": round(centroid, 3),
                   "density": round(density, 3), "gh": round(gh, 3)}


def _wobble(x):
    """f0 cents-std (pitch-modulation depth), robust to octave-jumps and
    capped — an unstable (sul-ponticello-cracking) render shouldn't explode
    the loss into a single dimension, just be strongly penalized."""
    try:
        t, f0, _ = sm.f0_track(x)
        ok = np.isfinite(f0)
        if ok.sum() < 10:
            return 0.0
        f = f0[ok]
        med = np.median(f)
        keep = np.abs(np.log2(f / med)) < 0.5      # drop octave/half-octave jumps
        if keep.sum() < 10:
            return 50.0                            # mostly unstable → max penalty
        c = 1200.0 * np.log2(f[keep] / np.median(f[keep]))
        return float(min(50.0, np.std(c)))
    except Exception:  # noqa: BLE001
        return 0.0


# ---------------------------------------------------------------------------
# Render one candidate against one ref

def render_and_score(name, vals, pinned, model, w, verbose=False):
    score, dur = build_score(name, vals, pinned, model)
    try:
        wav = run_score(name, score, timeout_s=max(40.0, dur + 25.0))
    except Exception as e:  # noqa: BLE001
        if verbose:
            print(f"      ! render {name} failed: {e}")
        return float("inf"), {"reason": "render-failed"}
    if not wait_stable_wav(str(wav)):
        if verbose:
            print(f"      ! render {name} produced an empty/short wav")
        return float("inf"), {"reason": "empty-wav"}
    ref_wav = os.path.join(REFS_DIR, model["name"], "reference.wav")
    return score_pair(ref_wav, str(wav), w, model)


# ---------------------------------------------------------------------------
# Checkpoint + trials

def write_partial(best_loss, best_vals):
    tm.atomic_write_json(LIVE_PARTIAL, {"loss": best_loss, "params": best_vals})


def log_trial(gen, ci, total, comps, refs):
    with open(TRIALS, "a") as f:
        f.write(json.dumps({"gen": gen, "ci": ci, "loss": total,
                            "refs": refs, "comp": comps,
                            "t": round(time.time(), 1)}) + "\n")


# ---------------------------------------------------------------------------
# Smoke test: confirm SWAM produces sound through the live app

def smoke(pinned):
    print("[smoke] rendering a fixed C4 note through the live app…")
    model = {"name": "smoke", "role": "primary", "midi": 60,
             "window": [0.0, 1.5], "segments": []}
    seed, _ = load_seed()
    score, dur = build_score("sar_smoke", seed, pinned, model)
    try:
        wav = run_score("sar_smoke", score, timeout_s=60.0)
    except Exception as e:  # noqa: BLE001
        raise SystemExit(f"[smoke] render failed — is StarpadMac running with "
                         f"the audition runner? ({e})")
    if not wait_stable_wav(str(wav)):
        raise SystemExit("[smoke] render produced an empty wav (flush race / "
                         "engine stalled).")
    x = load_resampled(str(wav))
    rms = float(np.sqrt(np.mean(x ** 2)))
    peak = float(np.max(np.abs(x)))
    print(f"[smoke] rms={rms:.5f} peak={peak:.4f} dur={len(x)/SR:.2f}s")
    if rms < 1e-3:
        raise SystemExit("[smoke] output is silent — SWAM Viola produced no "
                         "sound (unlicensed / not loaded / wrong preset). "
                         "Fix before running the loop (every candidate would "
                         "score identically).")
    print("[smoke] OK — SWAM is producing sound.")


# ---------------------------------------------------------------------------
# Materialize elites on ALL refs (incl. validation) + overlays + A/B audio

def _write_ab(path, ref, cand):
    gap = np.zeros(int(0.4 * SR))
    a = steady(ref); b = steady(cand)
    n = min(len(a), len(b), int(SUSTAIN_CAP * SR))
    a = a[:n] / (np.max(np.abs(a[:n])) + 1e-9)
    b = b[:n] / (np.max(np.abs(b[:n])) + 1e-9)
    out = np.concatenate([a, gap, b]).astype(np.float32)
    wavfile.write(path, SR, (out * 0.9 * 32767).astype(np.int16))


def materialize(params_path, w, pinned):
    data = json.load(open(params_path))
    vals = data.get("params", data)
    allrefs = [ANCHOR] + ROTATING + VALIDATION
    base = os.path.join(TOP, "winner")
    os.makedirs(base, exist_ok=True)
    tm.atomic_write_json(os.path.join(base, "params.json"), vals)
    print(f"[materialize] {params_path} on {len(allrefs)} refs -> {base}")
    summary = {}
    for rn in allrefs:
        mp = os.path.join(REFS_DIR, rn, "model.json")
        if not os.path.exists(mp):
            continue
        model = json.load(open(mp))
        if model.get("role") == "pluck":
            continue
        name = f"win_{rn}"
        total, comps = render_and_score(name, vals, pinned, model, w, verbose=True)
        summary[rn] = {"loss": round(total, 3), **comps}
        print(f"  {rn:9s} loss={total:7.3f}  {comps}")
        out_wav = os.path.join(sm.REPO, "auditions", "outputs", f"{name}.wav")
        ref_wav = os.path.join(REFS_DIR, rn, "reference.wav")
        try:
            r = load_resampled(ref_wav)
            c = load_resampled(out_wav)
            ir = hires_spec(r)
            ic = hires_spec(c)
            h = min(ir.shape[0], ic.shape[0]); ww = min(ir.shape[1], ic.shape[1])
            gap = np.full((6, ww, 3), 255, np.uint8)
            # ref spectrogram / cand spectrogram / clarity (valley-depth) panel
            pan = clarity_panel(r, c, model, ww)
            tm.write_png(os.path.join(base, f"{rn}_overlay.png"),
                         np.vstack([ir[:h, :ww], gap, ic[:h, :ww], gap, pan[:, :ww]]))
            _write_ab(os.path.join(base, f"{rn}_ab.wav"), r, c)
        except Exception as e:  # noqa: BLE001
            print(f"    (artifact failed: {e})")
    tm.atomic_write_json(os.path.join(base, "summary.json"), summary)
    print(f"[materialize] mean loss = "
          f"{np.mean([s['loss'] for s in summary.values()]):.3f}")


# ---------------------------------------------------------------------------
# Main loop

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gens", type=int, default=25)
    ap.add_argument("--lam", type=int, default=12)
    ap.add_argument("--sigma", type=float, default=0.4)
    ap.add_argument("--minutes", type=float, default=0.0,
                    help="hard wall-clock cap; stop at the next gen boundary")
    ap.add_argument("--resume", action="store_true",
                    help="seed the CMA mean from live_best.json.partial")
    ap.add_argument("--smoke", action="store_true",
                    help="only run the SWAM smoke render and exit")
    ap.add_argument("--materialize", metavar="PARAMS.json", default=None,
                    help="render a saved params file on all refs + artifacts")
    args = ap.parse_args()

    seed, pinned = load_seed()
    w = weights()

    if args.smoke:
        smoke(pinned)
        return
    if args.materialize:
        materialize(args.materialize, w, pinned)
        return

    # Always smoke-check first so we never burn a run on silent SWAM.
    smoke(pinned)

    # Seed (resume from partial if asked).
    if args.resume and os.path.exists(LIVE_PARTIAL):
        seed.update(json.load(open(LIVE_PARTIAL)).get("params", {}))
        print(f"[resume] seeded from {LIVE_PARTIAL}")
    z0 = np.array([value_to_z(seed[n], lo, hi, lg) for (n, lo, hi, lg) in DIMS])
    es = CMAES(z0, args.sigma, args.lam, seed=1234)
    elites = []   # (loss, vals)
    best_loss, best_vals = float("inf"), dict(seed)
    open(TRIALS, "w").close()
    t_start = time.time()
    print(f"[loop] {len(DIMS)} dims, lam={args.lam}, gens={args.gens}, "
          f"anchor={ANCHOR}, rotating={ROTATING}, weights={w}")

    for gen in range(args.gens):
        rot = ROTATING[gen % len(ROTATING)]
        refs = [ANCHOR, rot]
        models = [json.load(open(os.path.join(REFS_DIR, r, "model.json")))
                  for r in refs]
        zs = es.ask()
        fs = []
        for ci, z in enumerate(zs):
            vals = {n: z_to_value(z[i], lo, hi, lg)
                    for i, (n, lo, hi, lg) in enumerate(DIMS)}
            tot, allc = 0.0, {}
            for model in models:
                name = f"sar_g{gen:03d}_c{ci:02d}_{model['name']}"
                t, comps = render_and_score(name, vals, pinned, model, w)
                tot += t
                allc[model["name"]] = comps
            fs.append(tot)
            log_trial(gen, ci, tot, allc, refs)
            if tot < best_loss:
                best_loss, best_vals = tot, dict(vals)
                write_partial(best_loss, best_vals)
            elites.append((tot, dict(vals)))
        es.tell(zs, fs)
        elites = sorted([e for e in elites if np.isfinite(e[0])],
                        key=lambda t: t[0])[:10]
        el = time.time() - t_start
        print(f"[gen {gen:3d}] refs={refs} best={best_loss:.3f} "
              f"gen_best={min(f for f in fs if np.isfinite(f)):.3f} "
              f"sigma={es.sigma:.3f} elapsed={el/60:.1f}m")
        if args.minutes and el > args.minutes * 60:
            print(f"[loop] hit --minutes {args.minutes} cap at gen {gen} "
                  f"(dropped gens {gen+1}..{args.gens-1})")
            break

    tm.atomic_write_json(LIVE_BEST, {"loss": best_loss, "params": best_vals,
                                     "dims": [d[0] for d in DIMS]})
    print(f"\n[loop] best loss {best_loss:.3f} -> {LIVE_BEST}")
    print("[loop] materializing winner on all refs (incl. validation)…")
    materialize(LIVE_BEST, w, pinned)
    print("Listen to auditions/sarangi/live_top/winner/<ref>_ab.wav — the EAR "
          "is the acceptance bar (specres is loudness-normalized + smeared).")


if __name__ == "__main__":
    main()
