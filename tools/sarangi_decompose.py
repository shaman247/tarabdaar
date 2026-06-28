#!/usr/bin/env python3
"""Linear decomposition of a bowed sarangi recording.

We model a bowed sarangi as the INDEPENDENT (incoherent, power-additive) sum of
the main bowed string + each sympathetic (tarab) string, all colored by ONE
shared body/room EQ:

    P_i(f) = B(f) · [ Σ_h g_h²·δ(f − h·F_i)                  # main string
                    + Σ_j Σ_m c_ij·(s_j·t_m)²·δ(f − m·f_j) ]  # tarab string j

`sarangi4.wav` is the key: an ascending+descending run over 8 distinct notes
(Eb4..Eb5, the top octave of E♭ harmonic minor). The tarab strings are tuned to
E♭ harmonic minor at FIXED pitches (MIDI 51..75, 15 strings — see
`StarpadMac/SympatheticStringSet.swift::sarangiTarab`), so across the 8 notes the
sympathetic partials sit at the SAME frequencies while the main-string partials
MOVE with F_i. That difference, under one shared body, is the separation handle.

Unknowns and how they're identified (hybrid ALS, power domain):
  g_h  main harmonic profile (pitch-invariant)  ← clean main partials / B
  t_m  tarab modal profile (one shared timbre)   ← shape of clean symp partials / B
                                                    (fallback: sarangi1 plucks)
  s_j  per-string level   ·  c_ij coupling        ← clean symp levels; physics
                                                    prior fills thin strings
  B(f) body/room power transfer                   ← O/model at every clean partial
Gauges (convention, not data): g_1=1, max_m t_m=1, max_i c_ij=1 per j, mean log B=0.

Decay (τ_m → Q) is MEASURED from sarangi1 plucks, not solved here (this fits
steady-state AMPLITUDE). This tool VALIDATES the model (partial-domain residual,
reconstruction specres, main-only/symp-only spectrograms, coupling heatmap); it
does NOT bake — see the module footer for the documented bake follow-up.

Subcommands:
  extract     segment sarangi4, measure main+symp partial amplitudes per note
  decompose   hybrid ALS → g_h, t_m, s_j, c_ij, B(f)
  report      reconstruction residual + spectrograms + coupling heatmap
  audition    drive sym-render with the fitted tarab profile (hear it)

numpy/scipy only. Reuses tanpura_match (heterodyne/IO/specres/PNG) and
sarangi_match (segmentation, pluck profile, body formants). Atomic writes.
"""

import argparse
import json
import os
import subprocess
import sys

import numpy as np
from scipy import signal

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tanpura_match as tm   # noqa: E402
import sarangi_match as sm   # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REF_PLUCK = os.path.join(REPO, "sarangi1.wav")     # isolated tarab plucks
REF_BOW = os.path.join(REPO, "sarangi2.wav")       # a bowed note (audition drive)
SYM_RENDER = os.path.join(REPO, "Packages", "StarpadDSP", ".build",
                          "release", "sym-render")

SR = tm.SR

# --- Raga / tarab configuration (set by configure() from CLI; defaults below
# reproduce the original E♭-harmonic-minor / sarangi4.wav setup) ---
# Scale degrees as semitone offsets from the tonic. The tarab is tuned to the
# played raga (a mistuned tarab rings at unrelated pitches), so this is BOTH the
# tarab pitch-class filter and the played scale.
RAGAS = {
    "harmonic_minor": [0, 2, 3, 5, 7, 8, 11],   # sarangi2–8: E♭ harmonic minor
    "bhairav": [0, 1, 4, 5, 7, 8, 11],          # sarangi9–11: ♭2 ♭6 major
    "major": [0, 2, 4, 5, 7, 9, 11],
    "minor": [0, 2, 3, 5, 7, 8, 10],
}
NOTE_PC = {"C": 0, "C#": 1, "DB": 1, "D": 2, "D#": 3, "EB": 3, "E": 4, "F": 5,
           "F#": 6, "GB": 6, "G": 7, "G#": 8, "AB": 8, "A": 9, "A#": 10,
           "BB": 10, "B": 11}

SDIR_OUT = os.path.join(REPO, "auditions", "sarangi")   # bake-tarab init.json output
DDIR = os.path.join(REPO, "auditions", "sarangi", "decompose")
REF_SCALE = os.path.join(REPO, "sarangi4.wav")     # default: 8-note Eb harm-minor run
REF_SCALES = [REF_SCALE]                            # all refs pooled (D1); [0] is primary
OBS = os.path.join(DDIR, "observations.json")
DECOMP = os.path.join(DDIR, "decomposition.json")


def midi_hz(m):
    return 440.0 * 2.0 ** ((m - 69) / 12.0)


def tarab_for(tonic_pc, scale_offsets, lo, hi):
    """MIDI list of tarab strings: the scale's pitch classes within [lo, hi]."""
    pcs = {(tonic_pc + d) % 12 for d in scale_offsets}
    return [m for m in range(lo, hi + 1) if (m % 12) in pcs]


# E♭ harmonic minor, MIDI 51..75 (authoritative: SympatheticStringSet.sarangiTarab)
TARAB_MIDI = tarab_for(NOTE_PC["EB"], RAGAS["harmonic_minor"], 51, 75)
TARAB_HZ = [midi_hz(m) for m in TARAB_MIDI]


def configure(args):
    """Set the raga/reference globals from CLI args (shared by all subcommands)."""
    global REF_SCALE, REF_SCALES, DDIR, OBS, DECOMP, TARAB_MIDI, TARAB_HZ
    # --refs (D1) pools note instances across several recordings of the SAME raga
    # for tighter medians; --ref is the single-file alias. The first ref is the
    # primary (its timeline drives report's reconstruction).
    raw = getattr(args, "refs", None) or [args.ref]
    refs = [r for item in raw for r in str(item).split(",") if r.strip()]
    REF_SCALES = [r if os.path.isabs(r) else os.path.join(REPO, r) for r in refs]
    REF_SCALE = REF_SCALES[0]
    tonic_pc = (int(args.tonic) if args.tonic.lstrip("-").isdigit()
                else NOTE_PC[args.tonic.upper()])
    offs = ([int(s) for s in args.scale.split(",")] if args.scale
            else RAGAS[args.raga])
    lo, hi = (int(v) for v in args.tarab_range.split("-"))
    TARAB_MIDI = tarab_for(tonic_pc, offs, lo, hi)
    TARAB_HZ = [midi_hz(m) for m in TARAB_MIDI]
    name = args.name or os.path.splitext(os.path.basename(REF_SCALE))[0]
    DDIR = os.path.join(REPO, "auditions", "sarangi", "decompose", name)
    OBS = os.path.join(DDIR, "observations.json")
    DECOMP = os.path.join(DDIR, "decomposition.json")

H_MAIN = 28              # main-string harmonics to measure
M_SYMP = 12             # tarab modes per string to measure
FMAX = 14000.0          # ignore partials above this (heterodyne reaches ~0.45·SR)
COLLISION_CENTS = 25.0  # two partials within this collide (heterodyne can't split)
ATTACK_S = 0.15         # drop the bow attack from the steady window
RELEASE_S = 0.10        # drop the release tail
MIN_DUR = 0.5           # min stable-pitch run to count as a note instance
FLOOR_DB = -55.0        # per-note: partials this far below the loudest main are unusable
BGRID = np.geomspace(90.0, 16000.0, 96)   # log-freq grid for the body transfer
LBGRID = np.log(BGRID)
# The body/room transfer is a LOW-ORDER smooth curve in log-frequency (a few
# broad resonances), NOT a per-harmonic ripple. Representing B(f) on this small
# polynomial basis is what breaks the body↔source gauge ambiguity: B physically
# cannot carry the line-spectrum falloff, so g_h and t_m must.
B_ORDER = 6
_LMID = 0.5 * (np.log(90.0) + np.log(16000.0))
_LHALF = 0.5 * (np.log(16000.0) - np.log(90.0))


def b_basis(freq):
    """Polynomial basis [φ_0..φ_ORDER] in normalized log-frequency u∈[-1,1]."""
    u = (np.log(np.asarray(freq, float)) - _LMID) / _LHALF
    return np.stack([u ** k for k in range(B_ORDER + 1)], axis=-1)


def b_curve(beta):
    """Body log-power on BGRID from polynomial coefficients beta."""
    return b_basis(BGRID) @ beta


def cents(a, b):
    return 1200.0 * np.log2(a / b)


# ---------------------------------------------------------------------------
# Extraction: sarangi4 -> per-note pooled partial amplitudes

def steady_median(env_row, hop=tm.ENV_HOP):
    """Median amplitude over the steady part of a per-partial envelope row
    (drop attack + release). Median rejects vibrato/bow-noise transients."""
    n = len(env_row)
    s = int(ATTACK_S / hop)
    e = n - int(RELEASE_S / hop)
    if e - s < 4:                      # short note: keep the central half
        s, e = n // 4, n - n // 6
    seg = env_row[s:e]
    return float(np.median(seg)) if len(seg) else 0.0


def note_instances(x):
    """Segment sarangi4 and group pitch-stable runs by MIDI note. Returns
    {midi: [ {at, dur, f0}, ... ]} (each note appears ~twice: up + down)."""
    times, f0, rms = sm.f0_track(x)
    segs = sm.segment_notes(times, f0, min_dur=MIN_DUR)
    groups = {}
    for s in segs:
        groups.setdefault(s["midi"], []).append(
            {"at": s["at"], "dur": s["dur"], "f0": s["f0"]})
    return groups


def measure_note(x, instances):
    """Pool main + sympathetic partial amplitudes across all instances of one
    note. Each instance's main harmonics are tracked at its OWN refined f0
    (intonation drifts up to ~30 c); tarab modes are at the fixed f_j."""
    main_amps, symp_amps, Fs = [], [], []
    for inst in instances:
        i0 = int(inst["at"] * SR)
        i1 = min(len(x), int((inst["at"] + inst["dur"]) * SR))
        seg = x[i0:i1]
        if len(seg) < int(0.3 * SR):
            continue
        F = float(tm.refine_f0(seg, inst["f0"], span_cents=40, step_cents=2))
        Fs.append(F)
        Am = tm.measure_envelope_matrix(seg, F, n_harm=H_MAIN)
        main_amps.append([steady_median(Am[h]) for h in range(H_MAIN)])
        srow = []
        for fj in TARAB_HZ:
            Aj = tm.measure_envelope_matrix(seg, fj, n_harm=M_SYMP)
            srow.append([steady_median(Aj[m]) for m in range(M_SYMP)])
        symp_amps.append(srow)
    if not Fs:
        return None
    F = float(np.median(Fs))
    main = np.median(np.array(main_amps), axis=0)          # [H]
    symp = np.median(np.array(symp_amps), axis=0)          # [S, M]
    return F, main, symp


def classify(notes):
    """Mark each partial clean vs collision. A main harmonic h·F_i collides if
    any tarab mode m·f_j is within COLLISION_CENTS. A tarab mode m·f_j collides
    (for note i) if a main harmonic is within tol, OR if another tarab mode
    (different string) is within tol (tarab–tarab octave collisions — common in
    a harmonic-minor tuning). Clean partials drive the per-coefficient solves;
    collisions are held out and only checked in reconstruction."""
    # tarab mode frequencies (note-independent) for tarab–tarab collisions
    tmodes = [(j, m, (m + 1) * fj) for j, fj in enumerate(TARAB_HZ)
              for m in range(M_SYMP) if (m + 1) * fj <= FMAX]
    tar_ambig = {}
    for j, m, f in tmodes:
        amb = any(jj != j and abs(cents(f, ff)) < COLLISION_CENTS
                  for jj, mm, ff in tmodes)
        tar_ambig[(j, m)] = amb
    for nd in notes:
        F = nd["F"]
        mainf = [(h + 1) * F for h in range(H_MAIN)]
        ref = max((a for a in nd["main"]), default=1e-9) or 1e-9
        floor = ref * 10 ** (FLOOR_DB / 20.0)
        nd["main_rec"] = []
        for h in range(H_MAIN):
            f = mainf[h]
            if f > FMAX:
                continue
            coll = any(abs(cents(f, (m + 1) * fj)) < COLLISION_CENTS
                       for fj in TARAB_HZ for m in range(M_SYMP)
                       if (m + 1) * fj <= FMAX)
            nd["main_rec"].append({
                "h": h + 1, "freq": round(f, 2), "amp": nd["main"][h],
                "clean": (not coll) and nd["main"][h] > floor})
        nd["symp_rec"] = []
        for j, fj in enumerate(TARAB_HZ):
            for m in range(M_SYMP):
                f = (m + 1) * fj
                if f > FMAX:
                    continue
                amp = nd["symp"][j][m]
                main_coll = any(abs(cents(f, mf)) < COLLISION_CENTS
                                for mf in mainf if mf <= FMAX)
                clean = (amp > floor and not main_coll
                         and not tar_ambig.get((j, m), False))
                nd["symp_rec"].append({
                    "j": j, "m": m + 1, "freq": round(f, 2), "amp": amp,
                    "clean": clean, "main_coll": main_coll,
                    "tar_ambig": tar_ambig.get((j, m), False)})
    return notes


def cmd_extract(args):
    os.makedirs(DDIR, exist_ok=True)
    # Pool note instances across every --ref (D1): each file contributes its own
    # pitch-stable runs of every note; the per-note main/symp amplitudes are the
    # MEDIAN across all instances of all files (tighter than a single take). The
    # PRIMARY ref (REF_SCALES[0]) supplies the timeline (its instances) that
    # report's reconstruction replays. Pooling sharpens the observed modes but
    # adds NO new tarab-mode coverage when the extra refs play notes ⊂ the
    # primary's set (every Eb sample does) — pool for robustness, not coverage.
    stereo = stereo_discrepancy(REF_SCALES[0])
    per_midi = {}      # midi -> {"F":[...], "main":[...], "symp":[...], "ninst":n}
    prim_inst = {}     # midi -> primary-ref instances (for the timeline)
    for fi, path in enumerate(REF_SCALES):
        x = tm.load_wav_mono(path)
        groups = note_instances(x)
        for midi, insts in groups.items():
            res = measure_note(x, insts)
            if res is None:
                continue
            F, main, symp = res
            slot = per_midi.setdefault(midi, {"F": [], "main": [], "symp": [],
                                              "ninst": 0})
            slot["F"].append(F)
            slot["main"].append(main)
            slot["symp"].append(symp)
            slot["ninst"] += len(insts)
            if midi not in prim_inst:    # first file that has this note = timeline
                prim_inst[midi] = [{"at": i["at"], "dur": i["dur"]} for i in insts]
    notes = []
    for midi in sorted(per_midi):
        slot = per_midi[midi]
        F = float(np.median(slot["F"]))
        main = np.median(np.array(slot["main"]), axis=0)
        symp = np.median(np.array(slot["symp"]), axis=0)
        notes.append({
            "midi": midi, "name": note_name(midi), "F": round(F, 3),
            "n_inst": slot["ninst"],
            "instances": prim_inst[midi],
            "main": [round(float(a), 7) for a in main],
            "symp": [[round(float(a), 7) for a in row] for row in symp]})
    notes = classify(notes)
    out = {
        "source": [os.path.basename(p) for p in REF_SCALES], "sr": SR,
        "tarab_midi": TARAB_MIDI,
        "tarab_hz": [round(f, 3) for f in TARAB_HZ],
        "H_main": H_MAIN, "M_symp": M_SYMP, "fmax": FMAX,
        "collision_cents": COLLISION_CENTS, "floor_db": FLOOR_DB,
        "stereo_rms_diff_db": stereo, "notes": notes}
    tm.atomic_write_json(OBS, out)
    print(f"{len(notes)} notes: "
          + ", ".join(f"{n['name']}({n['n_inst']}x)" for n in notes))
    nclean_m = sum(r["clean"] for n in notes for r in n["main_rec"])
    nclean_s = sum(r["clean"] for n in notes for r in n["symp_rec"])
    print(f"clean partials — main {nclean_m}, symp {nclean_s}")
    print(f"stereo L/R band-RMS diff: {stereo:+.2f} dB  (fit is mono)")
    print(f"wrote {OBS}")


def note_name(midi):
    names = ["C", "C#", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]
    return f"{names[midi % 12]}{midi // 12 - 1}"


def stereo_discrepancy(path):
    """Mean |L-band-RMS − R-band-RMS| in dB across the 90 Hz–16 kHz grid —
    flags channel cancellation that mono-summing would hide."""
    import wave
    w = wave.open(path, "rb")
    ch = w.getnchannels()
    raw = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)
    w.close()
    if ch < 2:
        return 0.0
    st = raw.reshape(-1, ch).astype(np.float64) / 32768.0
    L = tm.abs_logspec_bands(st[:, 0]).mean(axis=1)
    R = tm.abs_logspec_bands(st[:, 1]).mean(axis=1)
    return round(float(np.mean(np.abs(L - R))), 3)


# ---------------------------------------------------------------------------
# Body transfer B(f): smooth, non-parametric, on a log-freq grid

def b_eval(bln, f):
    """B(f) as a linear POWER gain (bln is log-power on BGRID)."""
    return np.exp(np.interp(np.log(np.asarray(f, float)), LBGRID, bln))


# ---------------------------------------------------------------------------
# Physics coupling prior: driven-resonance harmonic overlap

def coupling_physics(notes, g, sigma=25.0):
    """c_ij ∝ Σ_h g_h² Σ_m exp(−(Δcents/σ)²): note i's harmonics landing near
    string j's modes, weighted by the driving harmonic's power. Per-string
    max-normalized (gauge max_i c_ij = 1)."""
    S = len(TARAB_HZ)
    C = np.zeros((len(notes), S))
    for i, nd in enumerate(notes):
        F = nd["F"]
        for j, fj in enumerate(TARAB_HZ):
            tot = 0.0
            for h in range(H_MAIN):
                fh = (h + 1) * F
                if fh > FMAX:
                    break
                gh2 = g[h] ** 2
                if gh2 <= 0:
                    continue
                ov = 0.0
                for m in range(M_SYMP):
                    fm = (m + 1) * fj
                    if fm > FMAX:
                        break
                    ov += np.exp(-((cents(fh, fm) / sigma) ** 2))
                tot += gh2 * ov
            C[i, j] = tot
    col = C.max(axis=0)
    col[col <= 0] = 1.0
    return C / col


# ---------------------------------------------------------------------------
# Hybrid ALS solve

def pluck_tarab_profile():
    """Fallback tarab modal profile t_m from sarangi1 isolated plucks
    (sarangi_match.pool_profile), plus per-mode decay τ. t normalized peak=1."""
    x = tm.load_wav_mono(REF_PLUCK)
    onsets, f0s, gain_db, tau_s, n = sm.measure_all(x, M_SYMP)
    t = 10 ** (gain_db[:M_SYMP] / 20.0)
    t = t / (t.max() + 1e-12)
    return t, tau_s[:M_SYMP], n


def _wls(eqs_fn, col, ncol, iters):
    """Weighted least squares with a couple of IRLS (Huber) robustness passes.
    eqs_fn() -> (list of [coeff_dict, y, weight], n_data_rows)."""
    x = None
    for it in range(max(1, iters)):
        eqs, n_data = eqs_fn()
        A = np.zeros((len(eqs), ncol))
        yv = np.zeros(len(eqs))
        wv = np.zeros(len(eqs))
        for ri, (c, y, w) in enumerate(eqs):
            for k, v in c.items():
                A[ri, col[k]] = v
            yv[ri] = y
            wv[ri] = w
        with np.errstate(all="ignore"):
            if x is not None and np.all(np.isfinite(x)):
                res = np.clip(A[:n_data] @ x - yv[:n_data], -50, 50)
                wv[:n_data] = wv[:n_data] / np.maximum(1.0, np.abs(res) / 1.5)
            x, *_ = np.linalg.lstsq(A * wv[:, None], yv * wv, rcond=1e-8)
        x = np.nan_to_num(np.clip(x, -200.0, 200.0))
    return x


def solve(notes, iters=3, coupling="hybrid", cover_min=3, sigma=25.0,
          ridge=0.02, gauge_w=50.0, body_tilt_w=4.0, body_curve_w=0.1):
    """One joint log-linear decomposition. Every partial is a LINEAR equation in
    log-power:
        main:  2·log O = ℓ_i + G_h + B(f)     (ℓ_i per-note bow level, G_h=log g_h²)
        symp:  2·log O = Lc_ij + T_m + B(f)   (Lc_ij=log c_ij s_j², T_m=log t_m²)

    Identifiability (hard-won): a per-note level ℓ_i is REQUIRED (the 8 notes are
    bowed >20 dB apart). The body B(f) is identifiable only up to a TILT+OFFSET
    that trades with ℓ_i/G_h/T_m (the source–filter degeneracy); its FORMANT
    curvature IS identifiable and matters (it keeps g_h pitch-invariant, spread
    ~4 dB vs ~10 dB without it). So B is a low-order log-f polynomial with its
    tilt gently gauged: g_h, t_m are body-corrected SOURCE profiles, B carries
    the broad formant envelope, ℓ_i the per-note loudness. Collisions (a played
    harmonic on a tarab mode — unavoidable in the tarab's own scale) go to MAIN;
    the tarab is read only from the CLEAN between-harmonic modes.
    Gauges: g_1=1 (G_1=0), Σ_i ℓ_i=0, Σ_m T_m=0, max_m t_m=1, max_i c_ij=1/string."""
    N = len(notes)
    t_pluck, tau, n_pluck = pluck_tarab_profile()

    # main: every above-floor cluster carrying a played harmonic (pure-main)
    main_cl = []   # (i, h, freq, amp, ref)
    for i, nd in enumerate(notes):
        clusters, ref = note_clusters(nd)
        for cl in clusters:
            for tg in cl["contribs"]:
                if tg[0] == "main":
                    main_cl.append((i, tg[1], cl["freq"], cl["amp"], ref))
    # symp: the clean between-harmonic tarab modes
    symp_obs = []
    for i, nd in enumerate(notes):
        ref = max((r["amp"] for r in nd["main_rec"]), default=1e-9) or 1e-9
        for r in nd["symp_rec"]:
            if r["clean"]:
                symp_obs.append((i, r["j"], r["m"], r["freq"],
                                 2 * np.log(r["amp"]), min(1.0, r["amp"] / ref)))
    cover = np.zeros(M_SYMP, int)
    for (_, _, m, _, _, _) in symp_obs:
        cover[m - 1] += 1
    obs_modes = sorted({m for (_, _, m, _, _, _) in symp_obs
                        if cover[m - 1] >= cover_min})
    symp_obs = [o for o in symp_obs if o[2] in obs_modes]
    pairs = sorted({(i, j) for (i, j, _, _, _, _) in symp_obs})

    col = {}
    for i in range(N):
        col[("L", i)] = len(col)
    for h in range(2, H_MAIN + 1):        # G_1 = 0 (gauge g_1 = 1)
        col[("G", h)] = len(col)
    for m in obs_modes:
        col[("T", m)] = len(col)
    for k in range(B_ORDER + 1):
        col[("Bc", k)] = len(col)
    for p in pairs:
        col[("Lc", p)] = len(col)

    def eqs_fn():
        eqs = []
        for (i, h, f, amp, ref) in main_cl:
            c = {("Bc", k): float(v) for k, v in enumerate(b_basis(f))}
            c[("L", i)] = 1.0
            if h >= 2:
                c[("G", h)] = 1.0
            eqs.append([c, 2.0 * np.log(amp), min(1.0, amp / ref)])
        for (i, j, m, f, y, w) in symp_obs:
            c = {("Bc", k): float(v) for k, v in enumerate(b_basis(f))}
            c[("T", m)] = 1.0
            c[("Lc", (i, j))] = 1.0
            eqs.append([c, y, w])
        n_data = len(eqs)
        eqs.append([{("L", i): 1.0 for i in range(N)}, 0.0, gauge_w])      # Σℓ=0
        if obs_modes:
            eqs.append([{("T", m): 1.0 for m in obs_modes}, 0.0, gauge_w])  # ΣT=0
        for k in range(B_ORDER + 1):      # body shape prior: gauge tilt, keep curve
            wk = 1e-6 if k == 0 else (body_tilt_w if k == 1 else body_curve_w)
            eqs.append([{("Bc", k): 1.0}, 0.0, wk])
        for key in col:
            if key[0] in ("L", "G", "T", "Lc"):
                eqs.append([{key: 1.0}, 0.0, ridge])
        return eqs, n_data

    x = _wls(eqs_fn, col, len(col), iters)
    g = np.ones(H_MAIN)
    for h in range(2, H_MAIN + 1):
        g[h - 1] = np.exp(0.5 * x[col[("G", h)]])
    ell = np.array([np.exp(x[col[("L", i)]]) for i in range(N)])
    bln = b_curve(np.array([x[col[("Bc", k)]] for k in range(B_ORDER + 1)]))
    t, P, filled = _decode_tarab(x, col, notes, obs_modes, pairs, t_pluck,
                                 coupling, g, sigma)
    C = _coupling_display(P)
    hist = [recon_residual(notes, g, t, P, bln, ell, mode="all")]
    return {
        "g": g, "t": t, "P": P, "C": C, "bln": bln, "ell": ell, "tau": tau,
        "body_ltas": body_ltas(REF_SCALE),
        "filled": filled, "cover": cover, "sigma": sigma,
        "coupling": coupling, "n_pluck": n_pluck, "resid_hist": hist}


def body_ltas(path):
    """Descriptive body/room EQ: the recording's smooth long-term-average
    spectrum on BGRID (dB, peak 0). NOT a separated filter — the body is not
    identifiable from one scale — just the overall spectral envelope."""
    x = tm.load_wav_mono(path)
    f, Pxx = signal.welch(x, SR, nperseg=8192, noverlap=4096)
    lf, ldb = np.log(np.maximum(f, 1.0)), 10 * np.log10(Pxx + 1e-13)
    grid = np.interp(LBGRID, lf, ldb)
    if len(grid) >= 11:
        grid = signal.savgol_filter(grid, 11, 3)
    return grid - grid.max()


def _decode_tarab(x, col, notes, obs_modes, pairs, t_pluck, coupling, g, sigma):
    """Tarab shape t_m (max-normalized, octave-collision modes falloff-filled) +
    per-(note,string) level P_ij = c_ij·s_j² (physics-filled where unexcited)."""
    N = len(notes)
    S = len(TARAB_HZ)
    if not obs_modes or not pairs:
        return t_pluck.copy(), np.zeros((N, S)), np.ones(M_SYMP, bool)
    t = np.full(M_SYMP, np.nan)
    for m in obs_modes:
        t[m - 1] = np.exp(0.5 * x[col[("T", m)]])
    covered = np.isfinite(t)
    ks = np.arange(1, M_SYMP + 1)
    filled = ~covered
    if covered.sum() >= 3 and coupling != "physics":
        A_, B_, _ = tm.fit_loglaw(ks[covered], t[covered])
        t = np.where(covered, np.nan_to_num(t), A_ * ks.astype(float) ** B_)
    else:
        t = t_pluck.copy()
        filled = np.ones(M_SYMP, bool)
    t = np.maximum(t, 1e-6)
    tmax = t.max()
    t = t / (tmax + 1e-12)                 # gauge max_m t = 1
    Pdata = {p: float(np.exp(x[col[("Lc", p)]]) * tmax ** 2) for p in pairs}
    scale = float(np.median(list(Pdata.values()))) if Pdata else 1.0
    Cphys = coupling_physics(notes, g, sigma)
    P = np.zeros((N, S))
    for i in range(N):
        for j in range(S):
            if (i, j) in Pdata:
                P[i, j] = Pdata[(i, j)]
            elif coupling != "free":
                P[i, j] = Cphys[i, j] * scale
    return t, P, filled


def _coupling_display(P):
    """Per-string max-normalized coupling c_ij (for the heatmap): how strongly
    each note excites each tarab string, relative to that string's loudest note."""
    col = P.max(axis=0)
    col = np.where(col > 0, col, 1.0)
    return P / col


def note_clusters(nd):
    """Group a note's candidate partials into frequency clusters (within
    COLLISION_CENTS). Heterodyne at nearby freqs sees the SAME energy, so a
    cluster shares ONE observed amplitude; its model power is the SUM of every
    contributor. Only clusters above the per-note floor are returned (silent
    partials carry no information). Singleton clusters == the clean partials."""
    ref = max((r["amp"] for r in nd["main_rec"]), default=1e-9) or 1e-9
    floor = ref * 10 ** (FLOOR_DB / 20.0)
    recs = [(r["freq"], r["amp"], ("main", r["h"])) for r in nd["main_rec"]]
    recs += [(r["freq"], r["amp"], ("symp", r["j"], r["m"]))
             for r in nd["symp_rec"]]
    recs.sort()
    cl = []
    for f, a, tag in recs:
        if cl and abs(cents(f, cl[-1]["freq"])) < COLLISION_CENTS:
            cl[-1]["amp"] = max(cl[-1]["amp"], a)
            cl[-1]["contribs"].append(tag)
        else:
            cl.append({"freq": f, "amp": a, "contribs": [tag]})
    return [c for c in cl if c["amp"] > floor], ref


def cluster_model_power(cl, i, g, t, P, bln, ell):
    """Model power of a cluster. A cluster with a main contributor is attributed
    to MAIN (the bow dominates its own harmonics) and gets the main model
    ℓ_i·g_h²·B — so the residual genuinely tests the pitch-invariant main fit. A
    PURE-symp cluster (the between-harmonic halo) is taken as MEASURED, because
    the per-mode tarab level extrapolates unreliably to un-observed modes; the
    fitted t_m/c_ij remain the reported profiles."""
    Bf = b_eval(bln, cl["freq"])
    mains = [tag for tag in cl["contribs"] if tag[0] == "main"]
    if mains:
        return sum(ell[i] * g[tag[1] - 1] ** 2 * Bf for tag in mains)
    return cl["amp"] ** 2     # measured halo


def recon_residual(notes, g, t, P, bln, ell, mode="all"):
    """Mean weighted |ΔdB| between observed and SUMMED-model cluster power.
    mode: 'all' | 'clean' (singleton clusters) | 'held' (collision clusters)."""
    num = den = 0.0
    for i, nd in enumerate(notes):
        clusters, ref = note_clusters(nd)
        for cl in clusters:
            single = len(cl["contribs"]) == 1
            if (mode == "clean" and not single) or (mode == "held" and single):
                continue
            mp = cluster_model_power(cl, i, g, t, P, bln, ell)
            num, den = _acc(num, den, cl["amp"], mp, ref)
    return round(num / (den + 1e-12), 4)


def _acc(num, den, amp, mdl_pow, ref):
    w = min(1.0, amp / ref)                # loud partials weigh more
    obs_db = 20 * np.log10(max(amp, 1e-9))
    mdl_db = 10 * np.log10(max(mdl_pow, 1e-18))
    return num + w * abs(obs_db - mdl_db), den + w


def cmd_decompose(args):
    obs = json.load(open(OBS))
    notes = obs["notes"]
    r = solve(notes, iters=args.iters, coupling=args.coupling,
              cover_min=args.cover_min, sigma=args.sigma)
    g, t, P, C, bln, ell = r["g"], r["t"], r["P"], r["C"], r["bln"], r["ell"]
    res_clean = recon_residual(notes, g, t, P, bln, ell, mode="clean")
    res_held = recon_residual(notes, g, t, P, bln, ell, mode="held")
    res_all = recon_residual(notes, g, t, P, bln, ell, mode="all")
    held = sum(len(note_clusters(n)[0]) for n in notes) \
        - sum(1 for n in notes for cl in note_clusters(n)[0]
              if len(cl["contribs"]) == 1)
    out = {
        "coupling": r["coupling"], "iters": args.iters, "sigma": r["sigma"],
        "gauge": "g_1=1, max_m t=1, max_i c=1/string (body tilt→source)",
        "g_main": [round(float(v), 6) for v in r["g"]],
        "g_main_db": [round(float(20 * np.log10(max(v, 1e-9))), 2) for v in r["g"]],
        "t_symp": [round(float(v), 6) for v in r["t"]],
        "t_symp_db": [round(float(20 * np.log10(max(v, 1e-9))), 2) for v in r["t"]],
        "tau_symp_s": [round(float(v), 4) for v in r["tau"]],
        "symp_level_P": [[round(float(v), 8) for v in row] for row in r["P"]],
        "main_level": [round(float(v), 6) for v in r["ell"]],
        "main_level_db": [round(float(10 * np.log10(max(v, 1e-12))), 2)
                          for v in r["ell"]],
        "coupling_matrix": [[round(float(v), 4) for v in row] for row in r["C"]],
        "body_grid_hz": [round(float(f), 1) for f in BGRID],
        "body_db": [round(float(10 * np.log10(np.exp(v))), 3) for v in r["bln"]],
        "body_ltas_db": [round(float(v), 3) for v in r["body_ltas"]],
        "body_db_note": "body_db = the fitted body B(f) (formant curvature is "
                        "identifiable; its overall tilt/offset is gauge-fixed, so "
                        "absolute level is not meaningful). body_ltas_db = the raw "
                        "recording LTAS for reference. g_h/t_m are body-corrected.",
        "tarab_mode_coverage": [int(c) for c in r["cover"]],
        "tarab_modes_law_filled": [int(m + 1) for m in range(M_SYMP)
                                   if r["filled"][m]],
        "note_midi": [n["midi"] for n in notes],
        "note_names": [n["name"] for n in notes],
        "n_pluck_fallback": r["n_pluck"],
        "held_out_collision_clusters": held,
        "recon_residual_clean_db": res_clean,
        "recon_residual_held_db": res_held,
        "recon_residual_all_db": res_all,
        "recon_residual_history": r["resid_hist"]}
    # body as formant bands for the bake handoff (seed only, from the LTAS)
    out["body_formants"] = body_band_fit(r["body_ltas"])
    tm.atomic_write_json(DECOMP, out)
    g_db = out["g_main_db"]
    t_db = out["t_symp_db"]
    print(f"coupling={r['coupling']} iters={args.iters}  clean residual "
          f"{r['resid_hist'][0]:.2f} -> {res_clean:.2f} dB   "
          f"held-out(collisions) {res_held:.2f} dB   all {res_all:.2f} dB")
    print("main g_h  (dB): " + " ".join(f"{v:5.1f}" for v in g_db[:12]))
    print("tarab t_m (dB): " + " ".join(f"{v:5.1f}" for v in t_db[:12]))
    print(f"tarab clean-mode coverage: {list(out['tarab_mode_coverage'])}")
    print(f"  modes law-filled (unobservable octave collisions): "
          f"{out['tarab_modes_law_filled']}")
    print(f"wrote {DECOMP}")


def body_band_fit(body_db, n=4):
    """Pick the n strongest peaks of the descriptive body LTAS (dB array on
    BGRID) as formant bands (freq, gainDB, Q) — a SEED for violaBody/postReverb,
    not a committed bake."""
    db = np.asarray(body_db, float)
    pk, props = signal.find_peaks(db, prominence=0.5)
    if len(pk) == 0:
        return []
    order = np.argsort(props["prominences"])[::-1][:n]
    out = []
    for p in sorted(pk[order]):
        out.append({"freq": round(float(BGRID[p]), 1),
                    "gainDB": round(float(db[p] - db.mean()), 2), "q": 4.0})
    return out


# ---------------------------------------------------------------------------
# Reconstruction synthesis (for spectrograms + holistic specres)

def synth_components(obs, dec):
    """Additive-sine reconstruction of sarangi4 on its own timeline. Returns
    (full, main_only, symp_only) mono buffers. MAIN is the model ℓ_i·g_h²·B (so
    the spectrogram shows whether the pitch-invariant main fit holds); the HALO
    is the MEASURED clean between-harmonic tarab energy (the per-mode level
    extrapolates unreliably)."""
    notes = obs["notes"]
    g = np.array(dec["g_main"])
    ell = np.array(dec["main_level"])
    bln = np.log(10 ** (np.array(dec["body_db"]) / 10.0))   # fitted body, power
    end = max(i["at"] + i["dur"]
              for n in notes for i in n["instances"]) + 0.3
    L = int(end * SR)
    full = np.zeros(L)
    main_o = np.zeros(L)
    symp_o = np.zeros(L)
    idx = {n["midi"]: i for i, n in enumerate(notes)}
    for n in notes:
        i = idx[n["midi"]]
        F = n["F"]
        clean_symp = [(r["freq"], r["amp"]) for r in n["symp_rec"] if r["clean"]]
        for inst in n["instances"]:
            i0 = int(inst["at"] * SR)
            ns = int(inst["dur"] * SR)
            tt = np.arange(ns) / SR
            env = np.ones(ns)
            ramp = int(0.04 * SR)
            if ns > 2 * ramp:
                env[:ramp] = 0.5 - 0.5 * np.cos(np.linspace(0, np.pi, ramp))
                env[-ramp:] = env[:ramp][::-1]
            mbuf = np.zeros(ns)
            sbuf = np.zeros(ns)
            for h in range(H_MAIN):
                f = (h + 1) * F
                if f > FMAX:
                    break
                a = np.sqrt(max(b_eval(bln, f), 0) * ell[i] * g[h] ** 2)
                mbuf += a * np.sin(2 * np.pi * f * tt)
            for ji, (f, amp) in enumerate(clean_symp):     # measured halo
                if f <= FMAX:
                    sbuf += amp * np.sin(2 * np.pi * f * tt + 0.7 * ji)
            mbuf *= env
            sbuf *= env
            full[i0:i0 + ns] += mbuf + sbuf
            main_o[i0:i0 + ns] += mbuf
            symp_o[i0:i0 + ns] += sbuf
    return full, main_o, symp_o


def heatmap(C, names):
    """Coupling matrix as an RGB block image (rows=notes, cols=tarab strings)."""
    N, S = C.shape
    cn = C / (C.max() + 1e-12)
    cell = 26
    img = np.zeros((N * cell, S * cell, 3), np.uint8)
    for i in range(N):
        for j in range(S):
            col = tm.colormap(np.array([cn[i, j]]))[0]
            img[i * cell:(i + 1) * cell, j * cell:(j + 1) * cell] = col
    img[::cell] = 60                       # grid lines
    img[:, ::cell] = 60
    return img


def cmd_report(args):
    obs = json.load(open(OBS))
    dec = json.load(open(DECOMP))
    notes = obs["notes"]
    C = np.array(dec["coupling_matrix"])

    # 1) per-note partial-domain residual + held-out (collision) residual
    g = np.array(dec["g_main"])
    t = np.array(dec["t_symp"])
    P = np.array(dec["symp_level_P"])
    ell = np.array(dec["main_level"])
    bln = np.log(10 ** (np.array(dec["body_db"]) / 10.0))   # fitted body
    print("per-note partial residual (dB)   clean / held-out collisions:")
    for i, n in enumerate(notes):
        cln = _note_resid(n, i, g, t, P, bln, ell, mode="clean")
        hld = _note_resid(n, i, g, t, P, bln, ell, mode="held")
        print(f"  {n['name']:4s} F={n['F']:7.2f}  clean {cln:5.2f}   held {hld:5.2f}")

    # 2) g_h cross-note spread (pitch-invariance test)
    spread = gh_spread(notes, bln, ell)
    print(f"g_h cross-note spread (median std over h, dB): {spread:.2f}  "
          f"(small = pitch-invariant main holds)")

    # 3) energy budget
    eb = energy_budget(notes, g, t, P, bln, ell)
    print(f"energy budget — main {eb['main']:.0%}  symp {eb['symp']:.0%}  "
          f"unexplained {eb['unexplained']:.0%}")

    # 4) holistic reconstruction specres vs real + spectrograms
    full, main_o, symp_o = synth_components(obs, dec)
    real = tm.load_wav_mono(REF_SCALE)[:len(full)]
    A, B, w = tm.specres_grids(real, full)
    sr_ = tm.specres_eval(A, B, w)
    print(f"reconstruction specres vs {os.path.basename(REF_SCALE)}: "
          f"slow {sr_['slow']:.2f}  "
          f"std {sr_['std']:.2f}  total {sr_['total']:.2f}")

    os.makedirs(DDIR, exist_ok=True)
    img_real = tm.logspec_image(real, fmin=120, fmax=12000)
    img_full = tm.logspec_image(full, fmin=120, fmax=12000)
    img_main = tm.logspec_image(main_o, fmin=120, fmax=12000)
    img_symp = tm.logspec_image(symp_o, fmin=120, fmax=12000)
    h = min(i.shape[0] for i in (img_real, img_full, img_main, img_symp))
    wd = min(i.shape[1] for i in (img_real, img_full, img_main, img_symp))
    gap = np.full((4, wd, 3), 255, np.uint8)
    stack = np.vstack([img_real[:h, :wd], gap, img_full[:h, :wd], gap,
                       img_main[:h, :wd], gap, img_symp[:h, :wd]])
    tm.write_png(os.path.join(DDIR, "reconstruction.png"), stack)
    tm.write_png(os.path.join(DDIR, "coupling.png"),
                 heatmap(C, dec["note_names"]))
    # save reconstruction audio for listening
    save_wav(os.path.join(DDIR, "recon_full.wav"), full)
    save_wav(os.path.join(DDIR, "recon_symp.wav"), symp_o)
    print("wrote reconstruction.png (real / full / main-only / symp-only),"
          " coupling.png, recon_full.wav, recon_symp.wav")
    print(f"  -> {DDIR}")


def _note_resid(n, i, g, t, P, bln, ell, mode="clean"):
    num = den = 0.0
    clusters, ref = note_clusters(n)
    for cl in clusters:
        single = len(cl["contribs"]) == 1
        if (mode == "clean" and not single) or (mode == "held" and single):
            continue
        mp = cluster_model_power(cl, i, g, t, P, bln, ell)
        num, den = _acc(num, den, cl["amp"], mp, ref)
    return num / (den + 1e-12)


def gh_spread(notes, bln, ell):
    """Std (dB) of the per-note g_h estimates (body- and level-corrected) at each
    harmonic, pooled — small ⇒ the main source profile really is pitch-invariant."""
    per_h = [[] for _ in range(H_MAIN)]
    for i, n in enumerate(notes):
        for r in n["main_rec"]:
            if r["clean"]:
                gh = r["amp"] / np.sqrt(max(b_eval(bln, r["freq"]) * ell[i], 1e-18))
                per_h[r["h"] - 1].append(20 * np.log10(max(gh, 1e-9)))
    stds = [np.std(v) for v in per_h if len(v) >= 3]
    return float(np.median(stds)) if stds else float("nan")


def energy_budget(notes, g, t, P, bln, ell):
    """Power split over audible clusters (no double-count): clusters with a main
    contributor count as MAIN (the played harmonic), pure-symp clusters as the
    between-harmonic HALO. Unexplained = observed power the model misses."""
    main = symp = obs = 0.0
    for i, n in enumerate(notes):
        clusters, _ = note_clusters(n)
        for cl in clusters:
            obs += cl["amp"] ** 2
            Bf = b_eval(bln, cl["freq"])
            if any(tag[0] == "main" for tag in cl["contribs"]):
                main += sum(ell[i] * g[tag[1] - 1] ** 2 * Bf
                            for tag in cl["contribs"] if tag[0] == "main")
            else:
                symp += cl["amp"] ** 2     # measured between-harmonic halo
    tot = main + symp
    return {"main": main / (tot + 1e-18), "symp": symp / (tot + 1e-18),
            "unexplained": max(0.0, (obs - tot)) / (obs + 1e-18)}


def save_wav(path, x):
    import wave
    pk = np.max(np.abs(x)) + 1e-12
    xi = (np.clip(x / pk * 0.9, -1, 1) * 32767).astype(np.int16)
    w = wave.open(path, "wb")
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(SR)
    w.writeframes(xi.tobytes())
    w.close()


# ---------------------------------------------------------------------------
# Audition: drive sym-render with the fitted tarab profile

def cmd_audition(args):
    dec = json.load(open(DECOMP))
    drive = args.drive or REF_BOW
    # Build a TanpuraParams whose string-0 tarab profile = the fitted t_m/τ_m.
    t = np.array(dec["t_symp"])
    gain_db = np.array((20 * np.log10(np.maximum(t, 1e-9))).tolist())
    tau = np.array(dec["tau_symp_s"])
    body = sm.body_formants_multi([REF_SCALE])     # {freq,gain,q} sym-render format
    params = sm.build_params(gain_db, tau, body, M_SYMP)
    freqs = [round(f, 2) for f in TARAB_HZ]
    out_wav = args.out_wav or os.path.join(DDIR, "audition_halo.wav")
    spec = {"driveWav": drive, "frequencies": freqs, "playedNotes": freqs,
            "sarangiParams": params, "out": out_wav}
    os.makedirs(DDIR, exist_ok=True)
    sp = out_wav + ".spec.json"
    tm.atomic_write_json(sp, spec)
    if not os.path.exists(SYM_RENDER):
        raise SystemExit(f"sym-render not built: {SYM_RENDER}\n"
                         "  swift build -c release --package-path Packages/StarpadDSP")
    r = subprocess.run([SYM_RENDER, sp, "--mono"], capture_output=True, text=True)
    os.remove(sp)
    if r.returncode != 0:
        raise SystemExit(f"sym-render failed: {r.stderr}")
    halo = tm.load_wav_mono(out_wav)
    bow = tm.load_wav_mono(drive)
    img_b = tm.logspec_image(bow, fmin=120, fmax=8000)
    img_h = tm.logspec_image(halo, fmin=120, fmax=8000)
    h = min(img_b.shape[0], img_h.shape[0])
    wd = min(img_b.shape[1], img_h.shape[1])
    gap = np.full((4, wd, 3), 255, np.uint8)
    out = os.path.join(DDIR, "audition.png")
    tm.write_png(out, np.vstack([img_b[:h, :wd], gap, img_h[:h, :wd]]))
    print(f"halo -> {out_wav}\nwrote {out}  (top: bow drive, bottom: fitted halo)")


# ---------------------------------------------------------------------------
# bake-tarab: build a BOWED-derived tarab resonator voicing from the decomposition
#
# The current SarangiParams bake is PLUCK-derived (sarangi1.wav), so it is
# fundamental-strong (falloff ~2.0). The real BOWED tarab's clean between-harmonic
# modes radiate a MUCH flatter per-mode profile (falloff ~1.0) — far less
# fundamental-dominated. That spectral SHAPE is the headline difference this tool
# captures: it pools the real recording's clean radiated tarab modes, fits a robust
# falloff law (+ clamped per-mode trims, law-filling the unobservable octave-
# collision modes), and writes a TanpuraParams init.json the baker can consume.
#
# We deliberately do NOT "deconvolve the drive" by default. In principle the
# resonator wants a RESONANCE gain and the recording gives a RADIATED amplitude
# (resonance × drive × body), but the drive at a BETWEEN-harmonic tarab mode is
# bow NOISE — NOT measurable from the recording (the full-recording Welch there is
# the tarab itself + leakage, which over-boosts the high modes by tens of dB when
# divided out). And the obvious empirical fix — render the halo driven by the real
# bow and match it — is DEGENERATE: the real recording already CONTAINS the tarab,
# so the rendered halo at m·f_j is dominated by the drive's own tarab content and
# the loop just makes gain cancel the body, measuring nothing. So the honest, fair
# A/B is the RADIATED shape itself: both the pluck and bowed bakes are radiated
# profiles driven through the same chain, so the A/B isolates the shape difference.
# (`--deconv gentle` applies a small CAPPED high-mode boost for experimentation.)

def _pool_clean_radiated(obs):
    """Per-mode RADIATED tarab profile (dB) pooled from the real recording's
    CLEAN between-harmonic modes (the audible halo) across all (note, string).
    Returns (db[M], coverage[M]); db normalized max(observed)=0."""
    vals = [[] for _ in range(M_SYMP)]
    for nd in obs["notes"]:
        for r in nd["symp_rec"]:
            if r["clean"] and r["amp"] > 0:
                vals[r["m"] - 1].append(r["amp"])
    cover = np.array([len(v) for v in vals])
    amp = np.array([np.median(v) if v else 0.0 for v in vals])
    db = 20.0 * np.log10(np.maximum(amp, 1e-9))
    obs_mask = cover > 0
    if obs_mask.any():
        db = db - db[obs_mask].max()
    return db, cover


def _bow_broadband_db(x):
    """Smoothed broadband log-power of the bow drive on a log-freq grid (only for
    the optional `--deconv gentle` capped high-mode boost). Returns (freqs, db)."""
    f, Pxx = signal.welch(x, SR, nperseg=8192, noverlap=4096)
    band = f >= 60.0
    fb = f[band]
    db = 10.0 * np.log10(Pxx[band] + 1e-13)
    if len(db) >= 31:
        db = signal.savgol_filter(db, 31, 3)
    return fb, db


def _regularize_gain(gain_db, obs_mask, res_clamp=6.0):
    """Robust falloff-law fit to the observed modes; law-FILL the unobserved modes
    onto the falloff; CLAMP observed residuals so a spike can't dominate. Returns
    (gain_db_regularized, falloff)."""
    ks = np.arange(1, M_SYMP + 1, dtype=float)
    if obs_mask.sum() < 3:
        return gain_db, 2.0
    A, B, _ = tm.fit_loglaw(ks[obs_mask], 10.0 ** (gain_db[obs_mask] / 20.0))
    law_db = 20.0 * np.log10(max(A, 1e-12)) + 20.0 * B * np.log10(ks)
    g = law_db.copy()                                  # unobserved -> on the law
    res = np.clip(gain_db[obs_mask] - law_db[obs_mask], -res_clamp, res_clamp)
    g[obs_mask] = law_db[obs_mask] + res
    return g, float(-B)


def _render_halo(params_or_path, drive_path, out_wav):
    """Drive `drive_path` through a tarab bank voiced by params (dict) or a
    TanpuraParams JSON path, write the halo to out_wav. Returns the halo buffer."""
    params = (params_or_path if isinstance(params_or_path, dict)
              else json.load(open(params_or_path)))
    spec = {"driveWav": drive_path,
            "frequencies": [round(f, 2) for f in TARAB_HZ],
            "playedNotes": [round(f, 2) for f in TARAB_HZ],
            "sarangiParams": params, "out": out_wav}
    sp = out_wav + ".spec.json"
    os.makedirs(os.path.dirname(out_wav), exist_ok=True)
    tm.atomic_write_json(sp, spec)
    r = subprocess.run([SYM_RENDER, sp, "--mono"], capture_output=True, text=True)
    os.remove(sp)
    if r.returncode != 0:
        raise SystemExit(f"sym-render failed: {r.stderr}")
    return tm.load_wav_mono(out_wav)


def cmd_bake_tarab(args):
    if not os.path.exists(OBS):
        raise SystemExit(f"no observations: {OBS}\n  run `extract` first")
    if not os.path.exists(SYM_RENDER):
        raise SystemExit(f"sym-render not built: {SYM_RENDER}\n"
                         "  swift build -c release --package-path Packages/StarpadDSP")
    obs = json.load(open(OBS))
    dec = json.load(open(DECOMP)) if os.path.exists(DECOMP) else {}
    # ring times stay the MEASURED pluck decays (the bowed solve borrows them; the
    # re-bake is about the per-mode GAIN profile, not Q).
    tau = np.array(dec.get("tau_symp_s", [0.2] * M_SYMP))[:M_SYMP]
    body = sm.body_formants_multi(REF_SCALES)
    drive = args.drive or REF_SCALES[0]
    drive_path = drive if os.path.isabs(drive) else os.path.join(REPO, drive)
    # carry the SAME mode count as the pluck fit (sm.N_HARM) so the bake is
    # apples-to-apples; modes beyond the 12 measured tarab modes law-fill onto the
    # bowed falloff (flat, ~0.99) rather than being absent.
    n_harm = max(sm.N_HARM, M_SYMP)

    # target: the real recording's clean radiated tarab per-mode (dB), and the
    # modes we trust (enough clean observations); the rest are law-filled.
    target_db, cover = _pool_clean_radiated(obs)
    obs_mask = cover >= args.cover_min

    boost = np.zeros(M_SYMP)
    if args.deconv == "gentle":
        # optional CAPPED high-mode boost (a partial, bounded drive correction —
        # the true between-harmonic drive is unmeasurable, so this is capped).
        fb, bdb = _bow_broadband_db(tm.load_wav_mono(drive_path))
        f_geo = float(np.exp(np.mean(np.log(TARAB_HZ))))
        drel = np.array([np.interp(np.log((m + 1) * f_geo), np.log(fb), bdb)
                         for m in range(M_SYMP)]) - \
            np.interp(np.log(f_geo), np.log(fb), bdb)
        boost = np.clip(-drel, 0.0, args.max_boost)

    gain_db = np.where(obs_mask, target_db + boost, -90.0)
    gain_db, falloff = _regularize_gain(gain_db, obs_mask, args.res_clamp)
    if obs_mask.any():
        gain_db = gain_db - gain_db[obs_mask].max()     # peak-normalize

    # pad to n_harm with the law tail so build_params/fit_laws sees a full profile
    full_db = np.full(n_harm, -90.0)
    full_db[:M_SYMP] = gain_db
    ks = np.arange(1, n_harm + 1, dtype=float)
    full_db[M_SYMP:] = -20.0 * falloff * np.log10(ks[M_SYMP:])
    params = sm.build_params(full_db, np.pad(tau, (0, n_harm - len(tau))),
                             body, n_harm)
    out_json = args.out or os.path.join(SDIR_OUT, "init_bowed.json")
    tm.atomic_write_json(out_json, params)

    # --- render both halos (bowed vs pluck) on the same drive for the EAR A/B ---
    work = os.path.join(DDIR, "bake_tarab")
    os.makedirs(work, exist_ok=True)
    bowed_wav = os.path.join(work, "halo_bowed.wav")
    halo_bowed = _render_halo(params, drive_path, bowed_wav)
    pluck_src = args.pluck or os.path.join(SDIR_OUT, "init.json")
    pluck_wav, halo_pluck = None, None
    if os.path.exists(pluck_src):
        pluck_wav = os.path.join(work, "halo_pluck.wav")
        halo_pluck = _render_halo(pluck_src, drive_path, pluck_wav)
        pluck_falloff = json.load(open(pluck_src))["strings"][0]["falloff"]
    else:
        pluck_falloff = float("nan")

    # 3-panel spectrogram: drive / bowed halo / pluck halo
    imgs = [tm.logspec_image(tm.load_wav_mono(drive_path), fmin=120, fmax=8000),
            tm.logspec_image(halo_bowed, fmin=120, fmax=8000)]
    labels = ["drive", "bowed halo"]
    if halo_pluck is not None:
        imgs.append(tm.logspec_image(halo_pluck, fmin=120, fmax=8000))
        labels.append("pluck halo")
    h = min(i.shape[0] for i in imgs)
    wd = min(i.shape[1] for i in imgs)
    gap = np.full((4, wd, 3), 255, np.uint8)
    stack = []
    for i, im in enumerate(imgs):
        if i:
            stack.append(gap)
        stack.append(im[:h, :wd])
    ab_png = os.path.join(work, "ab.png")
    tm.write_png(ab_png, np.vstack(stack))

    # --- diagnostics ---
    def _rough(v, mask):
        d = np.diff(v[mask])
        return float(np.std(d)) if len(d) else 0.0
    print(f"\ntarab re-bake (BOWED) — drive {os.path.basename(drive_path)}, "
          f"deconv={args.deconv}, body {[b['freq'] for b in body]}")
    print("  mode:           " + " ".join(f"{m:5d}" for m in range(1, 13)))
    print("  cover:          " + " ".join(f"{c:5d}" for c in cover[:12]))
    print("  radiated dB:    " + " ".join(f"{v:5.1f}" for v in target_db[:12]))
    print("  -> gain_db:     " + " ".join(f"{v:5.1f}" for v in gain_db[:12]))
    print(f"  falloff: bowed {falloff:.2f}  vs pluck {pluck_falloff:.2f}  "
          f"(lower = flatter / less fundamental-dominated)")
    print(f"  roughness radiated {_rough(target_db, obs_mask):.2f} dB "
          f"-> regularized {_rough(gain_db, obs_mask):.2f} dB")
    print(f"wrote {out_json}")
    print(f"wrote {ab_png}  (top→bottom: {', '.join(labels)})")
    print("\nLISTEN (the gate):")
    print(f"  bowed:  {bowed_wav}")
    if pluck_wav:
        print(f"  pluck:  {pluck_wav}")


# ---------------------------------------------------------------------------
# Bake targets: the isolated main-string g_h target (for the live SWAM match)
# + a comparison of the bowed-derived tarab/body against the current bake.

DECOMP_ROOT = os.path.join(REPO, "auditions", "sarangi", "decompose")
GH_TARGET = os.path.join(REPO, "auditions", "sarangi", "gh_target.json")
SARANGI_PARAMS = os.path.join(REPO, "Packages", "StarpadDSP", "Sources",
                              "StarpadDSP", "SarangiParams.swift")


def load_baked_tarab():
    """Extract the current baked tarab (pluck-derived) from SarangiParams.swift:
    per-mode gainTrimDB + the falloff/decay laws + body formants."""
    import re
    src = open(SARANGI_PARAMS).read()
    m = re.search(r'#\"\"\"(.*?)\"\"\"#', src, re.S)
    p = json.loads(m.group(1))
    s0 = p["strings"][0]
    return {"gainTrimDB": s0["gainTrimDB"], "falloff": s0["falloff"],
            "decay": s0["decay"], "body": p["body"]}


def cmd_target(args):
    """Average g_h across every decomposition run → the instrument's bow-timbre
    target (cross-raga, so it's instrument-intrinsic). Write gh_target.json for
    the live SWAM match, and print the bowed-vs-baked tarab + body comparison."""
    runs = sorted(glob_decomps())
    if not runs:
        raise SystemExit(f"no decompositions found under {DECOMP_ROOT}/*/ — "
                         "run `decompose` first")
    gset, names = [], []
    for path in runs:
        d = json.load(open(path))
        g = np.array(d["g_main_db"])
        gset.append(g - g[0])                        # normalize h1 = 0 dB
        names.append(os.path.basename(os.path.dirname(path)))
    G = np.array(gset)
    gh = np.median(G, axis=0)                         # robust cross-raga average
    spread = np.std(G, axis=0)
    # Truncate to the reliably-falling range: beyond the falloff the
    # decomposition's high harmonics are unconstrained (heterodyne at high h·F
    # reads noise/halo, not the quiet real harmonic) and snap back toward 0 dB.
    # Cut where g_h rises well above its running minimum or the two ragas diverge.
    run_min, cap = np.inf, len(gh)
    for h in range(len(gh)):
        run_min = min(run_min, gh[h])
        if h >= 3 and (gh[h] > run_min + 6.0 or spread[h] > 5.0):
            cap = h
            break
    gh, spread = gh[:cap], spread[:cap]
    print(f"reliable harmonics: 1–{cap} (high harmonics unconstrained, dropped)")
    # body curve (median across runs) — so the live metric can RADIATE the
    # body-corrected g_h at the candidate's pitch: target[h] = g_h[h] +
    # B(h·f0) − B(f0). Without it the body formants (e.g. the ~2.6 kHz peak)
    # make a real recording's measured comb mismatch the body-corrected target.
    bodies = [np.array(json.load(open(p))["body_db"]) for p in runs]
    body = np.median(np.array(bodies), axis=0)
    tm.atomic_write_json(GH_TARGET, {
        "note": "Isolated main bowed-string harmonic profile (dB, h1=0), pooled "
                "across ragas — the SWAM bow-timbre target for sarangi_iterate. "
                "g_main_db is the body-corrected SOURCE; body_db (on body_grid_hz) "
                "radiates it to a played pitch. Decontaminated from the halo.",
        "sources": names, "n_sources": len(names),
        "g_main_db": [round(float(v), 3) for v in gh],
        "g_spread_db": [round(float(v), 3) for v in spread],
        "body_grid_hz": [round(float(f), 1) for f in BGRID],
        "body_db": [round(float(v), 3) for v in body]})
    print(f"g_h bow target pooled over {len(names)} runs: {names}")
    print("  h:       " + " ".join(f"{h:5d}" for h in range(1, 13)))
    print("  g_h dB:  " + " ".join(f"{v:5.1f}" for v in gh[:12]))
    print("  ±spread: " + " ".join(f"{v:5.1f}" for v in spread[:12])
          + f"   (cross-raga agreement; median {np.median(spread[:16]):.1f} dB)")
    print(f"wrote {GH_TARGET}")

    # --- tarab comparison: bowed-derived (this tool) vs pluck-derived (baked) ---
    baked = load_baked_tarab()
    bg = np.array(baked["gainTrimDB"])
    h = np.arange(1, 13)
    baked_total = -20.0 * baked["falloff"] * np.log10(h) + bg[:12]   # resonance gain
    # the bowed-derived radiated tarab (from the richest run = most instances)
    rich = max(runs, key=lambda p: json.load(open(p)).get(
        "held_out_collision_clusters", 0))
    d = json.load(open(rich))
    t_db = np.array(d["t_symp_db"])
    print(f"\ntarab profile — bowed ({os.path.basename(os.path.dirname(rich))}) "
          f"vs pluck-derived bake (DIFFERENT quantities, see note):")
    print("  mode:           " + " ".join(f"{m:5d}" for m in range(1, 13)))
    print("  bowed t_m dB:   " + " ".join(f"{v:5.1f}" for v in t_db[:12])
          + "   (RADIATED under the bow = resonance×drive)")
    print("  baked res. dB:  " + " ".join(f"{v:5.1f}" for v in baked_total)
          + "   (RESONANCE gain from plucks)")
    print("  → not directly comparable: the bowed profile peaks mid (the high "
          "played notes weakly drive the low tarab modes), the pluck profile is "
          "fundamental-strong. A re-bake needs t_m deconvolved by the drive.")

    # --- body: fitted formants (seed) vs current ---
    print(f"\nbody formants — fitted (seed) {d.get('body_formants')}")
    print(f"               baked tarab body {baked['body']}")


def glob_decomps():
    out = []
    if os.path.isdir(DECOMP_ROOT):
        for n in os.listdir(DECOMP_ROOT):
            p = os.path.join(DECOMP_ROOT, n, "decomposition.json")
            if os.path.isfile(p):
                out.append(p)
    return out


# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    # Shared raga/reference config (default = E♭ harmonic minor / sarangi4.wav).
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--ref", default="sarangi4.wav",
                        help="scale-run WAV to decompose (e.g. sarangi11.wav)")
    common.add_argument("--refs", default=None, nargs="+",
                        help="multiple same-raga WAVs to POOL (D1), e.g. "
                             "`--refs sarangi4.wav sarangi3.wav` or a comma list; "
                             "the first is primary (drives the timeline)")
    common.add_argument("--tonic", default="Eb",
                        help="tonic note (Eb, D, …) or pitch class 0–11")
    common.add_argument("--raga", default="harmonic_minor",
                        choices=sorted(RAGAS), help="named scale for the tarab")
    common.add_argument("--scale", default=None,
                        help="explicit semitone offsets, e.g. 0,1,4,5,7,8,11 "
                             "(overrides --raga)")
    common.add_argument("--tarab-range", default="51-75",
                        help="tarab MIDI range lo-hi (e.g. 50-74 for D)")
    common.add_argument("--name", default=None,
                        help="output subdir under auditions/sarangi/decompose/ "
                             "(default: the ref basename)")
    sub = ap.add_subparsers(required=True)

    p = sub.add_parser("extract", parents=[common],
                       help="segment the ref scale + measure partials")
    p.set_defaults(fn=cmd_extract)

    p = sub.add_parser("decompose", parents=[common],
                       help="joint log-linear solve -> g_h, ℓ_i, t_m, c_ij, B")
    p.add_argument("--coupling", default="hybrid",
                   choices=["hybrid", "physics", "free"])
    p.add_argument("--iters", type=int, default=6)
    p.add_argument("--cover-min", type=int, default=3,
                   help="clean modes a tarab mode needs before data beats pluck")
    p.add_argument("--sigma", type=float, default=25.0,
                   help="driven-resonance half-width (cents) for the physics prior")
    p.set_defaults(fn=cmd_decompose)

    p = sub.add_parser("report", parents=[common],
                       help="residual + spectrograms + heatmap")
    p.set_defaults(fn=cmd_report)

    p = sub.add_parser("audition", parents=[common],
                       help="sym-render the fitted tarab profile")
    p.add_argument("--drive", default=None, help="drive WAV (default sarangi2.wav)")
    p.add_argument("--out-wav", default=None)
    p.set_defaults(fn=cmd_audition)

    p = sub.add_parser("bake-tarab", parents=[common],
                       help="build a BOWED-derived tarab resonator init.json from "
                            "the decomposition + render a bowed-vs-pluck A/B")
    p.add_argument("--drive", default=None,
                   help="bow drive WAV for the A/B renders (default: primary ref)")
    p.add_argument("--deconv", default="none", choices=["none", "gentle"],
                   help="none = fair radiated-shape A/B (default); gentle = small "
                        "capped high-mode drive boost (experimental)")
    p.add_argument("--max-boost", type=float, default=12.0,
                   help="cap (dB) for the --deconv gentle high-mode boost")
    p.add_argument("--cover-min", type=int, default=3,
                   help="clean observations a mode needs to be trusted (else law-filled)")
    p.add_argument("--res-clamp", type=float, default=6.0,
                   help="max per-mode residual (dB) off the falloff law")
    p.add_argument("--pluck", default=None,
                   help="pluck init.json for the A/B (default auditions/sarangi/init.json)")
    p.add_argument("--out", default=None,
                   help="output init.json (default auditions/sarangi/init_bowed.json)")
    p.set_defaults(fn=cmd_bake_tarab)

    p = sub.add_parser("target", help="emit the cross-raga g_h SWAM bow target "
                       "+ compare bowed tarab/body vs the current bake")
    p.set_defaults(fn=cmd_target)

    args = ap.parse_args()
    if getattr(args, "ref", None) is not None:
        configure(args)
    args.fn(args)


if __name__ == "__main__":
    main()
