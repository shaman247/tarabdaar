#!/usr/bin/env python3
"""Bake a matched tanpura parameter set into the Swift defaults.

Takes auditions/tanpura/best_params.json (the optimizer's winner),
peak-normalizes masterGain against a full-schedule render (target peak
0.6 — well under the output limiter's 0.85 knee; the loss RMS-normalizes,
so the optimizer never sets a meaningful absolute gain itself), then
rewrites the default literals in
Packages/StarpadDSP/Sources/StarpadDSP/TanpuraParams.swift in place.

--bump additionally increments `TanpuraParams.matchedVersion`, which keys
AppController's UserDefaults persistence — bump whenever the baked sound
changes so stale persisted params don't shadow it.

After baking: `swift test` in Packages/StarpadDSP (the model tests are
bake-independent and must stay green) and `./tools/build-mac.sh`.

Usage:
  python3 tools/tanpura_bake_defaults.py [--params PATH] [--bump] [--check]
"""

import argparse
import json
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SWIFT = os.path.join(REPO, "Packages", "StarpadDSP", "Sources", "StarpadDSP",
                     "TanpuraParams.swift")
RENDER_BIN = os.path.join(REPO, "Packages", "StarpadDSP", ".build", "release",
                          "tanpura-render")
REF_MODEL = os.path.join(REPO, "auditions", "tanpura", "reference_model.json")

SCALARS = {"jivaDepth": 3, "jivaRate": 3, "jivaTilt": 3, "jivaConserve": 3,
           "jivaRateSpread": 3, "pitchDriftCents": 3,
           "pitchDriftRate": 3, "pluckVariationDB": 3, "noiseLevel": 3,
           "noiseDecay": 4, "noiseFreq": 1, "noiseQ": 3, "crossExcite": 3,
           "crossTolCents": 1, "panSpread": 3, "bodyDry": 3, "tiltDB": 2,
           "masterGain": 4, "roomWetDB": 2, "roomDecayS": 3, "roomDamp": 3,
           "roomPredelayMs": 2}


def fmt(v, nd=4):
    s = f"{v:.{nd}f}".rstrip("0").rstrip(".")
    return s if "." in s else s + ".0"


def arr(vals, nd):
    return "[" + ", ".join(fmt(v, nd) for v in vals) + "]"


def peak_normalize(p, target=0.6):
    """Render the measured schedule, scale masterGain for `target` peak."""
    import wave
    import numpy as np
    model = json.load(open(REF_MODEL))
    plucks = [{"at": e["at"], "string": e["string"],
               "velocity": e.get("velocity", 0.8)}
              for e in model["events"] if e["at"] < 31.0]
    spec = {"durationSeconds": 32.0, "seed": 4242, "params": p,
            "plucks": plucks, "out": "/tmp/bake_norm.wav"}
    with open("/tmp/bake_norm.json", "w") as f:
        json.dump(spec, f)
    subprocess.run([RENDER_BIN, "/tmp/bake_norm.json", "--mono"],
                   check=True, capture_output=True)
    w = wave.open("/tmp/bake_norm.wav", "rb")
    x = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)
    w.close()
    peak = float(np.abs(x).max()) / 32768.0
    if peak > 1e-6:
        p["masterGain"] = round(p["masterGain"] * target / peak, 4)
    return p, peak


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--params",
                    default=os.path.join(REPO, "auditions", "tanpura",
                                         "best_params.json"))
    ap.add_argument("--bump", action="store_true",
                    help="increment TanpuraParams.matchedVersion")
    ap.add_argument("--no-normalize", action="store_true")
    ap.add_argument("--check", action="store_true",
                    help="parse + report only; write nothing")
    args = ap.parse_args()

    p = json.load(open(args.params))
    if not args.no_normalize:
        if not os.path.exists(RENDER_BIN):
            subprocess.run(["swift", "build", "-c", "release", "--package-path",
                            os.path.join(REPO, "Packages", "StarpadDSP")],
                           check=True)
        p, pre_peak = peak_normalize(p)
        print(f"peak-normalized: pre-peak {pre_peak:.3f} -> masterGain {p['masterGain']}")
        if not args.check:
            with open(args.params + ".tmp", "w") as f:
                json.dump(p, f, indent=1, sort_keys=True)
            os.replace(args.params + ".tmp", args.params)

    src = open(SWIFT).read()
    src = re.sub(r"(public var harmonicCount: Int = )\d+",
                 rf"\g<1>{int(p['harmonicCount'])}", src)
    for name, nd in SCALARS.items():
        src, n = re.subn(rf"(public var {name}: Double = )[0-9.\-]+",
                         rf"\g<1>{fmt(p[name], nd)}", src)
        if n != 1:
            sys.exit(f"bake failed: expected exactly one `{name}` default, found {n}")
    if args.bump:
        m = re.search(r"public static let matchedVersion = (\d+)", src)
        if not m:
            sys.exit("bake failed: matchedVersion not found")
        src = re.sub(r"(public static let matchedVersion = )\d+",
                     rf"\g<1>{int(m.group(1)) + 1}", src)
        print(f"matchedVersion {m.group(1)} -> {int(m.group(1)) + 1}")

    body_lines = ",\n".join(
        f"        TanpuraBodyBand(freq: {fmt(b['freq'],1)}, gain: {fmt(b['gain'],3)}, q: {fmt(b['q'],2)})"
        for b in p["body"])
    src, n = re.subn(r"public var body: \[TanpuraBodyBand\] = \[\n(?:.*\n)*?    \]",
                     "public var body: [TanpuraBodyBand] = [\n" + body_lines + ",\n    ]", src)
    if n != 1:
        sys.exit("bake failed: body array not matched")

    blocks = []
    for s in p["strings"]:
        blocks.append(f"""        TanpuraStringParams(
            f0: {fmt(s['f0'],2)}, level: {fmt(s['level'],3)}, falloff: {fmt(s['falloff'],3)},
            pluckPos: {fmt(s['pluckPos'],3)}, decay: {fmt(s['decay'],3)}, dampTilt: {fmt(s['dampTilt'],3)},
            bloomDelay: {fmt(s['bloomDelay'],3)}, bloomSkew: {fmt(s['bloomSkew'],3)},
            attackLevel: {fmt(s['attackLevel'],3)}, attackDecay: {fmt(s['attackDecay'],4)},
            inharmonicity: {fmt(s['inharmonicity'],6)}, subLevelDB: {fmt(s.get('subLevelDB', -60),2)}, subFalloff: {fmt(s.get('subFalloff', 1.6),3)}, subKneeH: {fmt(s.get('subKneeH', 64),2)},
            gainTrimDB: {arr(s['gainTrimDB'],2)},
            peakTrim: {arr(s['peakTrim'],3)},
            decayTrim: {arr(s['decayTrim'],3)})""")
    src, n = re.subn(r"public var strings: \[TanpuraStringParams\] = \[\n(?:.*\n)*?    \]",
                     "public var strings: [TanpuraStringParams] = [\n" + ",\n".join(blocks) + ",\n    ]", src)
    if n != 1:
        sys.exit("bake failed: strings array not matched")

    if args.check:
        print("check OK (nothing written)")
        return
    with open(SWIFT + ".tmp", "w") as f:
        f.write(src)
    os.replace(SWIFT + ".tmp", SWIFT)
    print(f"baked into {SWIFT}")
    print("now: (cd Packages/StarpadDSP && swift build -c release && swift test) "
          "&& ./tools/build-mac.sh")


if __name__ == "__main__":
    main()
