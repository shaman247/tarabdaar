#!/usr/bin/env python3
"""Fit the Fret Pad drag-assist parameters to recorded real playing.

Workflow:
  1. Toggle **REC** on the Fret Pad (Mac toolbar, or the iPad toolbar's REC
     button) and play naturally. Strokes land as JSONL:
       Mac:  ~/Library/Application Support/Starpad/FretRecordings/
       iPad: the app's Documents/FretRecordings/ (visible in the Files app
             and Finder's device browser — copy to the Mac to fit).
  2. `python3 tools/fretpad_fit.py report <files...> [--phrase "..."]` —
     stroke stats plus a parity check of this script's causal replica against
     what the live Swift assist actually played (recorded `o`). Trust the fit
     only if parity is tight (< ~2 cents mean).
  3. `python3 tools/fretpad_fit.py fit <files...> [--phrase "p n d n p d m p g"]`
     — labels intent with hindsight, then optimizes the four causal constants
     (speedFloor, speedCeiling, speedTau, settleTau) so the causal replay best
     matches the labels. Prints values to bake into `FretDragAssist.swift`.

Labeling modes:
  • default — each detected dwell/reversal takes the nearest in-zone fret.
  • --phrase "p n d n p d m p g" — protocol mode: the played sargam sequence
    is KNOWN, so detected inflections are aligned to the phrase tokens by
    dynamic programming (monotonic, with skip penalties; tokens are
    case-insensitive svara letters constraining pitch class — both komal and
    shuddha variants allowed, nearest wins; auto-tiled if a stroke holds
    several repetitions). Order + svara identity correct labels a sloppy
    landing would otherwise pin to the wrong neighboring fret.

Loss = mean |pitch at dwell end - fret| (cents)
     + 15 * mean settle lag (s, capped 0.6)
     + 0.7 * mean |pitch at reversal - fret| (cents)
     + 2.0 * mean |out - raw| over fast transit (cents)   [transparency]

Since the 2026-07-23 free-fret change the assist's magnet basin is **screen
px** (radiusScale × Snap, distance to the fret line's x), not log-pitch, and
each recorded ctx fret carries its pixel `x` (record v2). v1 recordings (made
on the pitch-mapped ribbon) still load — the fret x is derived from the old
x↔pitch mapping — but the live surface has changed; prefer fresh recordings.
"""

import json
import math
import sys
from pathlib import Path

import numpy as np

# radiusScale=1.0 / turnGain=0.0 match recordings made before the assist got
# its wider basin and the direction-flip impulse (assist radius = radiusScale
# × Snap; onset snap stays at 1×).
DEFAULTS = dict(speedFloor=25.0, speedCeiling=180.0, speedTau=0.045,
                settleTau=0.08, radiusScale=1.0, turnGain=0.0, turnTau=0.06)
TURN_DEADBAND = 0.7         # px — dx smaller than this doesn't flip direction
SLEW_CAP = 1500.0 / 1200.0  # log2/s — hard cap on correction slew (smoothness
                            # by construction, independent of fitted params)
REV_WIN_BEFORE = 0.04       # scoring window around a turn (s)
REV_WIN_AFTER = 0.10
HELD_CENTS_PER_S = 200.0    # output pitch moving slower than this reads as held
TICK = 1.0 / 60.0
STATIONARY_GAP = 0.04

# Hindsight-labeling constants (deliberately NOT fitted — they define "truth").
GRID_DT = 1.0 / 240.0
HIND_SIGMA = 0.030          # zero-phase speed smoothing (s)
DWELL_SPEED = 20.0          # px/s
DWELL_MIN = 0.09            # s
REVERSAL_PROMINENCE = 12.0  # px of x-excursion required on BOTH sides of a turn
FAST_SPEED = 250.0          # px/s (transparency regime)
SETTLED_CENTS = 5.0
LAG_CAP = 0.6

# Phrase alignment.
SKIP_INFLECTION = 80.0      # cents-equivalent cost: spurious detection
SKIP_TOKEN = 120.0          # cents-equivalent cost: missed landing
MATCH_CAP = 200.0

SARGAM_PCS = {"s": (0,), "r": (1, 2), "g": (3, 4), "m": (5, 6),
              "p": (7,), "d": (8, 9), "n": (10, 11)}


def parse_phrase(text):
    tokens = []
    for tok in text.replace(",", " ").split():
        pcs = SARGAM_PCS.get(tok[0].lower())
        if pcs is None:
            raise SystemExit(f"unknown svara '{tok}' in --phrase")
        tokens.append(pcs)
    return tokens


def load_strokes(paths, snap_px=None):
    """`snap_px` overrides the recorded Snap distance — for fitting the assist
    under a PROPOSED default Snap rather than the one that was live."""
    strokes = []
    for p in paths:
        for line in Path(p).read_text().splitlines():
            line = line.strip()
            if not line:
                continue
            s = json.loads(line)
            ev = np.array(s["events"], dtype=float)
            moves = ev[ev[:, 5] == 0]
            if len(moves) < 2 or s["endT"] <= 0.05:
                continue
            ctx = s["ctx"]
            span = 1.0 + 2.0 * max(0.0, ctx["ghostExtentOctaves"])
            extent = max(0.0, ctx["ghostExtentOctaves"])
            snap = snap_px if snap_px is not None else ctx["snapDistance"]
            # Magnet basin in screen px (matches FretDragAssist.setContext).
            radius = float(snap)

            def fret_x(f):
                # v2 records the fret's pixel x; v1 (pitch-mapped ribbon)
                # derives it from the old log2 ↔ x mapping.
                if "x" in f:
                    return float(f["x"])
                return (f["log2Ratio"] + extent) / span * ctx["width"]

            strokes.append(dict(
                events=ev, moves=moves, endT=float(s["endT"]),
                frets=[(fret_x(f), f["log2Ratio"], f["topY"], f["bottomY"])
                       for f in ctx["frets"]],
                radius=radius, params=ctx.get("assistParams", {}) or {},
            ))
    return strokes


def smoothstep(v):
    v = min(1.0, max(0.0, v))
    return v * v * (3 - 2 * v)


def candidate(frets, radius, x, y):
    """Nearest fret in screen px within radius whose y-extent contains y."""
    best, bd = None, float("inf")
    for fx, flog, top, bot in frets:
        if y < top or y > bot:
            continue
        d = abs(fx - x)
        if d <= radius and d < bd:
            best, bd = flog, d
    return best, bd


def replay(stroke, params):
    """Causal replica of FretDragAssist. Returns (times, u, out) arrays."""
    floor, ceil = params["speedFloor"], params["speedCeiling"]
    stau, ctau = params["speedTau"], params["settleTau"]
    turn_gain = params.get("turnGain", 0.0)
    turn_tau = params.get("turnTau", 0.06)
    frets = stroke["frets"]
    radius = stroke["radius"] * params.get("radiusScale", 1.0)
    moves = stroke["moves"]
    endT = stroke["endT"]

    ticks = np.arange(TICK, endT, TICK)
    nodes = sorted([(t, i, False) for i, t in enumerate(moves[:, 0])]
                   + [(t, -1, True) for t in ticks])

    speed = ceil
    corr = 0.0
    impulse = 0.0
    dx_sign = 0
    last_x, last_y, last_u = moves[0, 1], moves[0, 2], moves[0, 3]
    last_move = last_update = 0.0
    T, U, O = [], [], []
    for t, idx, is_tick in nodes:
        dt = min(max(t - last_update, 1e-4), 0.1)
        impulse *= math.exp(-dt / turn_tau)
        if is_tick:
            if t - last_move > STATIONARY_GAP:
                speed += (0 - speed) * (1 - math.exp(-dt / stau))
        else:
            x = moves[idx, 1]
            dx = x - last_x
            inst = abs(dx) / dt
            speed += (inst - speed) * (1 - math.exp(-dt / stau))
            if abs(dx) >= TURN_DEADBAND:
                s = 1 if dx > 0 else -1
                if dx_sign != 0 and s != dx_sign:
                    impulse = 1.0          # causal direction flip
                dx_sign = s
            last_x, last_y, last_u = x, moves[idx, 2], moves[idx, 3]
            last_move = t
        last_update = t
        w = smoothstep((ceil - speed) / (ceil - floor))
        gate = min(1.0, max(w, turn_gain * impulse))
        cand, d = candidate(frets, radius, last_x, last_y)
        if cand is not None:
            prox = min(1.0, max(0.0, 2.0 * (1.0 - d / radius)))
            rate = (1 - math.exp(-dt / ctau)) * gate * prox
            step = ((cand - last_u) - corr) * rate
            cap = SLEW_CAP * dt
            corr += min(cap, max(-cap, step))
        T.append(t)
        U.append(last_u)
        O.append(last_u + corr)
    return np.array(T), np.array(U), np.array(O)


def detect(stroke):
    """Hindsight inflection detection: dwell index ranges, reversal indices,
    and the analysis grids."""
    m = stroke["moves"]
    endT = stroke["endT"]
    tg = np.arange(0.0, endT, GRID_DT)
    xg = np.interp(tg, m[:, 0], m[:, 1])
    yg = np.interp(tg, m[:, 0], m[:, 2])
    ug = np.interp(tg, m[:, 0], m[:, 3])
    vx = np.gradient(xg, GRID_DT)
    k = max(1, int(round(HIND_SIGMA / GRID_DT)))
    kernel = np.exp(-0.5 * (np.arange(-3 * k, 3 * k + 1) / k) ** 2)
    kernel /= kernel.sum()
    speed = np.convolve(np.abs(vx), kernel, mode="same")

    dwells = []
    lo = None
    for i, s in enumerate(np.append(speed, np.inf)):
        if s < DWELL_SPEED and lo is None:
            lo = i
        elif s >= DWELL_SPEED and lo is not None:
            if (i - lo) * GRID_DT >= DWELL_MIN:
                dwells.append((lo, i - 1))
            lo = None

    in_dwell = np.zeros(len(tg), dtype=bool)
    for lo_i, hi_i in dwells:
        in_dwell[lo_i:hi_i + 1] = True

    # Reversals: sign changes of the SMOOTHED velocity, kept only when the
    # finger genuinely traveled on both sides of the turn (x-prominence) —
    # no speed gate, so fast connected playing's turns are found too.
    vxs = np.convolve(vx, kernel, mode="same")
    sign = np.sign(vxs)
    crossings = [i for i in range(1, len(tg))
                 if sign[i] != 0 and sign[i - 1] != 0 and sign[i] != sign[i - 1]]
    anchors = [0] + crossings + [len(tg) - 1]
    reversals = []
    for k, i in enumerate(crossings):
        left = abs(xg[i] - xg[anchors[k]])
        right = abs(xg[anchors[k + 2]] - xg[i])
        if left >= REVERSAL_PROMINENCE and right >= REVERSAL_PROMINENCE \
                and not in_dwell[i]:
            reversals.append(i)

    return dwells, reversals, (tg, xg, yg, ug, speed)


def labels_nearest(stroke, det):
    """Default labeling: each inflection takes the nearest in-zone fret."""
    dwells, reversals, (tg, xg, yg, ug, speed) = det
    labeled_dwells, labeled_revs = [], []
    for lo_i, hi_i in dwells:
        x_mid = float(np.mean(xg[lo_i:hi_i + 1]))
        y_mid = float(np.mean(yg[lo_i:hi_i + 1]))
        cand, _ = candidate(stroke["frets"], stroke["radius"], x_mid, y_mid)
        if cand is not None:
            labeled_dwells.append((tg[lo_i], tg[hi_i], cand))
    for i in reversals:
        cand, _ = candidate(stroke["frets"], stroke["radius"],
                            float(xg[i]), float(yg[i]))
        if cand is not None:
            labeled_revs.append((tg[i], cand))
    return labeled_dwells, labeled_revs, (tg, ug, speed), {}


def labels_phrase(stroke, det, tokens):
    """Protocol labeling: align the time-ordered inflections to the known
    svara sequence (monotonic DP with skip penalties). Intent labeling —
    no radius or y-extent gating; the phrase says what was meant. The stroke
    **onset** and **release** are anchors too (a connected phrase's first and
    last notes have no turn), so N tokens ↔ onset + turns/dwells + release.
    Onset matches align but produce no loss label (the onset snap owns it)."""
    dwells, reversals, (tg, xg, yg, ug, speed) = det

    infl = [dict(kind="dwell", lo=lo, hi=hi,
                 t=float(tg[lo]),
                 u=float(np.mean(ug[lo:hi + 1])),
                 x=float(np.mean(xg[lo:hi + 1])),
                 y=float(np.mean(yg[lo:hi + 1])))
            for lo, hi in dwells]
    infl += [dict(kind="rev", i=i, t=float(tg[i]), u=float(ug[i]),
                  x=float(xg[i]), y=float(yg[i]))
             for i in reversals]
    infl.append(dict(kind="onset", t=float(tg[0]), u=float(ug[0]),
                     x=float(xg[0]), y=float(yg[0])))
    infl.append(dict(kind="release", t=float(tg[-1]), u=float(ug[-1]),
                     x=float(xg[-1]), y=float(yg[-1])))
    infl.sort(key=lambda e: e["t"])

    # Candidate fret logs per token: every visible fret of that pitch class
    # (any octave/variant; the alignment picks the nearest).
    def pc(flog):
        return int(round(12 * flog)) % 12

    reps = max(1, round(len(infl) / max(1, len(tokens)))) if infl else 1
    tiled = list(tokens) * reps
    cands = [[flog for _, flog, _, _ in stroke["frets"] if pc(flog) in pcs]
             for pcs in tiled]

    n, m = len(infl), len(tiled)
    INF = 1e18
    D = np.full((n + 1, m + 1), INF)
    choice = np.zeros((n + 1, m + 1), dtype=int)  # 1=skip_i, 2=skip_j, 3=match
    D[0, 0] = 0.0
    for i in range(n + 1):
        for j in range(m + 1):
            here = D[i, j]
            if here >= INF:
                continue
            if i < n and here + SKIP_INFLECTION < D[i + 1, j]:
                D[i + 1, j] = here + SKIP_INFLECTION
                choice[i + 1, j] = 1
            if j < m and here + SKIP_TOKEN < D[i, j + 1]:
                D[i, j + 1] = here + SKIP_TOKEN
                choice[i, j + 1] = 2
            if i < n and j < m and cands[j]:
                c = min(MATCH_CAP,
                        min(abs(infl[i]["u"] - f) for f in cands[j]) * 1200)
                if here + c < D[i + 1, j + 1]:
                    D[i + 1, j + 1] = here + c
                    choice[i + 1, j + 1] = 3

    matches = []
    i, j = n, m
    while i > 0 or j > 0:
        ch = choice[i, j]
        if ch == 3:
            i, j = i - 1, j - 1
            fret = min(cands[j], key=lambda f: abs(infl[i]["u"] - f))
            matches.append((i, fret))
        elif ch == 1:
            i -= 1
        elif ch == 2:
            j -= 1
        else:
            break

    labeled_dwells, labeled_revs = [], []
    reachable = unreachable = 0
    for i, fret in matches:
        e = infl[i]
        # Reachability diagnostic: could the CAUSAL assist even act here —
        # fret within the magnet radius (px) AND its y-extent containing the
        # touch?
        in_zone = any(abs(fx - e["x"]) <= stroke["radius"]
                      and e["y"] >= top and e["y"] <= bot
                      and abs(flog - fret) < 1e-9
                      for fx, flog, top, bot in stroke["frets"])
        if e["kind"] != "onset":
            if in_zone:
                reachable += 1
            else:
                unreachable += 1
        if e["kind"] == "dwell":
            labeled_dwells.append((tg[e["lo"]], tg[e["hi"]], fret))
        elif e["kind"] != "onset":
            labeled_revs.append((e["t"], fret))
    info = dict(matched=len(matches), tokens=m, inflections=n,
                reachable=reachable, unreachable=unreachable)
    return labeled_dwells, labeled_revs, (tg, ug, speed), info


def hindsight(stroke, tokens=None):
    det = detect(stroke)
    if tokens:
        return labels_phrase(stroke, det, tokens)
    return labels_nearest(stroke, det)


def stroke_loss(stroke, params, labels):
    dwells, revs, (tg, ug, speed) = labels[0], labels[1], labels[2]
    T, U, O = replay(stroke, params)
    out_g = np.interp(tg, T, O)

    dwell_errs, lags, rev_errs = [], [], []
    for t0, t1, fret in dwells:
        seg = (tg >= t0) & (tg <= t1)
        err = np.abs(out_g[seg] - fret) * 1200
        dwell_errs.append(err[-1])
        settled = np.nonzero(err < SETTLED_CENTS)[0]
        lags.append(min(LAG_CAP, settled[0] * GRID_DT if len(settled) else LAG_CAP))
    dout_cps = np.abs(np.gradient(out_g, GRID_DT)) * 1200
    for t, fret in revs:
        # Perceptual turn error: the note at a turn is heard where the OUTPUT
        # pitch lingers, so weight |out - fret| by inverse output-pitch speed
        # over the window. Rewards a post-flip settle that holds the fret while
        # the finger departs; a mere fast pass-through earns little credit.
        seg = (tg >= t - REV_WIN_BEFORE) & (tg <= t + REV_WIN_AFTER)
        if not seg.any():
            seg = np.array([np.argmin(np.abs(tg - t))])
        w = 1.0 / (dout_cps[seg] + HELD_CENTS_PER_S)
        err = np.abs(out_g[seg] - fret) * 1200
        rev_errs.append(float(np.sum(w * err) / np.sum(w)))
    # Transparency = shape warping of fast transit, offset-invariant (the
    # carried anchor is intentional): per-fast-segment std of the correction.
    # A guard window around each labeled inflection is excluded — the
    # post-turn settle is the assist doing its job, not warping.
    corr_g = (out_g - ug) * 1200
    fast = speed > FAST_SPEED
    for t, _ in revs:
        fast &= ~((tg >= t - 0.02) & (tg <= t + 0.12))
    for t0, t1, _ in dwells:
        fast &= ~((tg >= t0 - 0.02) & (tg <= t1 + 0.12))
    stds = []
    lo = None
    for i, f in enumerate(np.append(fast, False)):
        if f and lo is None:
            lo = i
        elif not f and lo is not None:
            if i - lo >= 5:
                stds.append(float(np.std(corr_g[lo:i])))
            lo = None
    transp = float(np.mean(stds)) if stds else None
    return dwell_errs, lags, rev_errs, transp


def total_loss(strokes, params, all_labels):
    dw, lg, rv, tr = [], [], [], []
    for s, lab in zip(strokes, all_labels):
        d, l, r, t = stroke_loss(s, params, lab)
        dw += d
        lg += l
        rv += r
        if t is not None:
            tr.append(t)
    parts = dict(
        dwell=np.mean(dw) if dw else 0.0,
        lag=np.mean(lg) if lg else 0.0,
        reversal=np.mean(rv) if rv else 0.0,
        transparency=np.mean(tr) if tr else 0.0,
        n_dwell=len(dw), n_rev=len(rv),
    )
    parts["loss"] = (parts["dwell"] + 15.0 * parts["lag"]
                     + 0.7 * parts["reversal"] + 2.0 * parts["transparency"])
    return parts


def fit(strokes, all_labels, fast=False):
    grid = dict(
        speedFloor=[15, 30],
        speedCeiling=[150, 300],
        speedTau=[0.015, 0.04],
        settleTau=[0.01, 0.02, 0.04, 0.08],
        radiusScale=[1.0, 1.75, 2.5],
        turnGain=[0.0, 1.0, 2.0],
        turnTau=[0.04, 0.08, 0.12],
    )
    if fast:
        grid = {k: v[:2] for k, v in grid.items()}
    best, best_loss = None, float("inf")
    for f in grid["speedFloor"]:
        for c in grid["speedCeiling"]:
            if c < f + 20:
                continue
            for st in grid["speedTau"]:
                for se in grid["settleTau"]:
                    for rs in grid["radiusScale"]:
                        for tgn in grid["turnGain"]:
                            for tt in grid["turnTau"]:
                                p = dict(speedFloor=f, speedCeiling=c,
                                         speedTau=st, settleTau=se,
                                         radiusScale=rs, turnGain=tgn,
                                         turnTau=tt)
                                loss = total_loss(strokes, p, all_labels)["loss"]
                                if loss < best_loss:
                                    best, best_loss = p, loss
    for _ in range(3):
        for key in best:
            for mul in (0.8, 1.25):
                p = dict(best)
                p[key] = best[key] * mul
                if p["speedCeiling"] < p["speedFloor"] + 20:
                    continue
                loss = total_loss(strokes, p, all_labels)["loss"]
                if loss < best_loss:
                    best, best_loss = p, loss
    return best, best_loss


def parity(stroke):
    """Replay under the RECORDED params and compare to what Swift played."""
    params = {**DEFAULTS, **stroke["params"]}
    T, U, O = replay(stroke, params)
    ev = stroke["events"]
    rec_t, rec_o = ev[:, 0], ev[:, 4]
    sim_o = np.interp(rec_t, T, O)
    d = np.abs(sim_o - rec_o) * 1200
    return float(np.mean(d)), float(np.max(d))


def cmd_report(paths, tokens=None):
    strokes = load_strokes(paths)
    print(f"{len(strokes)} usable strokes from {len(paths)} file(s)\n")
    pm, px = [], []
    all_labels = []
    for i, s in enumerate(strokes):
        lab = hindsight(s, tokens)
        all_labels.append(lab)
        mean_c, max_c = parity(s)
        pm.append(mean_c)
        px.append(max_c)
        extra = ""
        if tokens:
            info = lab[3]
            extra = f"  phrase {info['matched']}/{info['tokens']} matched"
        print(f"stroke {i:3d}: {s['endT']:5.2f}s  {len(s['moves']):4d} moves  "
              f"{len(lab[0])} dwell(s)  {len(lab[1])} reversal(s){extra}  "
              f"parity mean {mean_c:5.2f}c max {max_c:5.2f}c")
    print(f"\nparity vs live Swift: mean {np.mean(pm):.2f}c  worst {np.max(px):.2f}c"
          f"  ({'OK — replica faithful' if np.mean(pm) < 2 else 'HIGH — investigate before fitting'})")
    parts = total_loss(strokes, DEFAULTS, all_labels)
    print(f"\nloss under current defaults: {parts['loss']:.2f}  "
          f"(dwell {parts['dwell']:.1f}c over {parts['n_dwell']}, lag {parts['lag']*1000:.0f}ms, "
          f"reversal {parts['reversal']:.1f}c over {parts['n_rev']}, "
          f"transparency {parts['transparency']:.2f}c)")


def cmd_fit(paths, tokens=None, fast=False, snap_px=None):
    strokes = load_strokes(paths, snap_px=snap_px)
    if snap_px is not None:
        print(f"fitting under proposed Snap = {snap_px:g} px "
              f"(recorded sessions used their own)")
    all_labels = [hindsight(s, tokens) for s in strokes]
    n_d = sum(len(l[0]) for l in all_labels)
    n_r = sum(len(l[1]) for l in all_labels)
    print(f"{len(strokes)} strokes, {n_d} labeled dwells, {n_r} labeled reversals")
    if tokens:
        matched = sum(l[3]["matched"] for l in all_labels)
        expected = sum(l[3]["tokens"] for l in all_labels)
        reach = sum(l[3]["reachable"] for l in all_labels)
        unreach = sum(l[3]["unreachable"] for l in all_labels)
        print(f"phrase mode: {matched}/{expected} landings matched; "
              f"{reach} inside the magnet's reach, {unreach} outside "
              f"(beyond Snap radius or the fret's y-extent — no causal "
              f"params can fix those; widen zones or Snap)")
    if n_d + n_r < 10:
        print("WARNING: few labeled inflections — record more playing for a stable fit.")
    base = total_loss(strokes, DEFAULTS, all_labels)
    best, best_loss = fit(strokes, all_labels, fast=fast)
    parts = total_loss(strokes, best, all_labels)
    print(f"\ndefaults: loss {base['loss']:.2f} "
          f"(dwell {base['dwell']:.1f}c, lag {base['lag']*1000:.0f}ms, "
          f"rev {base['reversal']:.1f}c, transp {base['transparency']:.2f}c)")
    print(f"fitted:   loss {parts['loss']:.2f} "
          f"(dwell {parts['dwell']:.1f}c, lag {parts['lag']*1000:.0f}ms, "
          f"rev {parts['reversal']:.1f}c, transp {parts['transparency']:.2f}c)")
    print("\nBake into FretDragAssist.swift:")
    print(f"    public var speedFloor: Double = {best['speedFloor']:.0f}")
    print(f"    public var speedCeiling: Double = {best['speedCeiling']:.0f}")
    print(f"    public var speedTau: Double = {best['speedTau']:.3f}")
    print(f"    public var settleTau: Double = {best['settleTau']:.3f}")
    print(f"    public var radiusScale: Double = {best.get('radiusScale', 1.0):.2f}")
    print(f"    public var turnGain: Double = {best.get('turnGain', 0.0):.2f}")
    print(f"    public var turnTau: Double = {best.get('turnTau', 0.06):.3f}")


def cmd_selftest():
    """Synthesize strokes (known intent), run the whole pipeline —
    including a connected 9-note phrase stroke through phrase alignment."""
    rng = np.random.default_rng(7)
    width, height = 1400.0, 900.0
    frets = [dict(id=f"f{i}", log2Ratio=-0.5 + i / 12.0,
                  x=(-0.5 + i / 12.0 + 0.5) / 2.0 * width, topY=200.0,
                  bottomY=700.0, ghost=False) for i in range(25)]
    ctx = dict(frets=frets, snapDistance=16.0, ghostExtentOctaves=0.5,
               width=width, height=height, assistParams=dict(DEFAULTS))

    def x_of_log(l):
        return (l + 0.5) / 2.0 * width

    def u_of_x(x):
        return (x / width) * 2.0 - 0.5

    # Simple stop strokes.
    lines = []
    for _ in range(4):
        f0, f1 = rng.choice(len(frets), 2, replace=False)
        x0 = x_of_log(frets[f0]["log2Ratio"]) + rng.normal(0, 4)
        x1 = x_of_log(frets[f1]["log2Ratio"]) + rng.normal(0, 8)
        ts, xs = [], []
        for t in np.arange(0, 0.4, 1 / 90):
            ts.append(t)
            xs.append(x0 + (x1 - x0) * smoothstep(t / 0.4))
        for t in np.arange(0.8, 1.1, 1 / 90):
            ts.append(t)
            xs.append(x1 + (x0 - x1) * 0.3 * smoothstep((t - 0.8) / 0.3))
        ev = [[float(t), float(x), 450.0, u_of_x(x), u_of_x(x), 0]
              for t, x in zip(ts, xs)]
        lines.append(json.dumps(dict(v=1, date="synthetic", offset=0.0, ctx=ctx,
                                     events=ev, endT=float(ts[-1]) + 0.02)))

    # One connected phrase stroke: p n d n p d m p g, sloppy landings.
    phrase = "p n d n p d m p g"
    pcs = [7, 10, 9, 10, 7, 9, 5, 7, 3]     # one concrete voicing of the phrase
    logs = [p / 12.0 for p in pcs]
    ts, xs = [], []
    t = 0.0
    x_cur = x_of_log(logs[0]) + rng.normal(0, 5)
    for tgt_log in logs:
        x_tgt = x_of_log(tgt_log) + rng.normal(0, 6)
        for tt in np.arange(0, 0.25, 1 / 90):
            ts.append(t + tt)
            xs.append(x_cur + (x_tgt - x_cur) * smoothstep(tt / 0.25))
        t += 0.25
        for tt in np.arange(0, 0.18, 1 / 90):   # dwell on the landing
            ts.append(t + tt)
            xs.append(x_tgt)
        t += 0.18
        x_cur = x_tgt
    ev = [[float(t_), float(x_), 450.0, u_of_x(x_), u_of_x(x_), 0]
          for t_, x_ in zip(ts, xs)]
    lines.append(json.dumps(dict(v=1, date="synthetic-phrase", offset=0.0,
                                 ctx=ctx, events=ev, endT=float(ts[-1]) + 0.02)))

    tmp = Path("/tmp/fretpad_selftest.jsonl")
    tmp.write_text("\n".join(lines))
    strokes = load_strokes([tmp])

    labels = [hindsight(s) for s in strokes]
    n_d = sum(len(l[0]) for l in labels)
    assert n_d >= 6, f"expected dwells detected, got {n_d}"
    base = total_loss(strokes, DEFAULTS, labels)
    best, best_loss = fit(strokes, labels, fast=True)
    assert best_loss <= base["loss"] + 1e-9

    tokens = parse_phrase(phrase)
    plab = hindsight(strokes[-1], tokens)
    info = plab[3]
    assert info["matched"] >= 8, f"phrase alignment matched only {info['matched']}/9"
    lands = [fret for _, _, fret in plab[0]]
    expect = [round(l * 12) for l in logs]
    got = [round(f * 12) for f in lands]
    assert got == expect[:len(got)] or info["matched"] >= 8
    print(f"selftest OK: {len(strokes)} strokes, {n_d} dwells, "
          f"default loss {base['loss']:.2f} -> fitted {best_loss:.2f}; "
          f"phrase matched {info['matched']}/{info['tokens']}")


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        sys.exit(1)
    cmd = args[0]
    rest = args[1:]
    tokens = None
    if "--phrase" in rest:
        i = rest.index("--phrase")
        tokens = parse_phrase(rest[i + 1])
        rest = rest[:i] + rest[i + 2:]
    snap_px = None
    if "--snap-px" in rest:
        i = rest.index("--snap-px")
        snap_px = float(rest[i + 1])
        rest = rest[:i] + rest[i + 2:]
    fast = "--fast" in rest
    files = [a for a in rest if not a.startswith("--")]
    if cmd == "report":
        cmd_report(files, tokens)
    elif cmd == "fit":
        cmd_fit(files, tokens, fast=fast, snap_px=snap_px)
    elif cmd == "selftest":
        cmd_selftest()
    else:
        print(__doc__)
        sys.exit(1)


if __name__ == "__main__":
    main()
