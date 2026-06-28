#!/usr/bin/env python3
"""Bake the fitted sitar params into the StarpadDSP Swift defaults.

Reads auditions/sitar/best_params.json (the CMA-ES winner), peak-normalizes
masterGain on the matched 3-pluck schedule (the optimizer never sets a
meaningful absolute gain — the loss RMS-normalizes — so we scale for a 0.6
peak at bake time, exactly like the tanpura bake), strips the optimizer's
`_`-prefixed bookkeeping keys, mirrors the single fitted voice onto all four
model strings (all tuned to 280.4 Hz, ready for the sitar tab / sympathetic
use), and rewrites the embedded JSON in
`Packages/StarpadDSP/Sources/StarpadDSP/SitarParams.swift`, bumping
`sitarMatchedVersion` so persisted UserDefaults can't shadow the new bake.

  python3 tools/sitar_bake_defaults.py [--params best.json] [--bump]
"""

import argparse
import json
import os
import subprocess
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import sitar_match as S          # noqa: E402
import tanpura_match as tm       # noqa: E402

SWIFT = os.path.join(S.REPO, "Packages", "StarpadDSP", "Sources",
                     "StarpadDSP", "SitarParams.swift")
F0 = S.F0


def peak_of(params, seed=0x5EED_1A4B):
    tmp = os.path.join(S.SDIR, "work", "_bakepeak.wav")
    os.makedirs(os.path.dirname(tmp), exist_ok=True)
    x = S.render(params, tmp, seed=seed)
    try:
        os.remove(tmp)
    except OSError:
        pass
    return float(np.max(np.abs(x)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--params", default=S.BEST)
    ap.add_argument("--bump", action="store_true")
    ap.add_argument("--peak", type=float, default=0.6)
    args = ap.parse_args()

    p = json.load(open(args.params))
    # Strip optimizer bookkeeping keys.
    for k in [k for k in p if k.startswith("_")]:
        del p[k]

    # The single fitted voice is string 0. Mirror it onto all four strings
    # (all at 280.4 Hz) so the tab / sympathetic layer can pluck any of
    # them; crossExcite stays 0 (not searched) so they stay independent.
    voice = json.loads(json.dumps(p["strings"][0]))
    voice["f0"] = F0
    p["strings"] = [json.loads(json.dumps(voice)) for _ in range(4)]
    p["crossExcite"] = 0.0

    # Peak-normalize masterGain for a clean 0.6 peak on the matched schedule.
    p["masterGain"] = 0.2
    pk = peak_of(p)
    if pk > 1e-6:
        p["masterGain"] = float(np.clip(p["masterGain"] * args.peak / pk,
                                        0.0, 1.0))
    print(f"masterGain -> {p['masterGain']:.4f} (peak was {pk:.3f} @ 0.2)")

    # Determine the new matched version.
    version = 1
    if os.path.exists(SWIFT):
        for line in open(SWIFT):
            if "sitarMatchedVersion" in line and "=" in line:
                try:
                    version = int(line.split("=")[1].strip().split()[0])
                except (ValueError, IndexError):
                    pass
    if args.bump or not os.path.exists(SWIFT):
        version += 0 if not os.path.exists(SWIFT) else 1

    blob = json.dumps(p, indent=2, sort_keys=True)
    # indent the JSON for the Swift multiline string
    swift = f'''import Foundation

/// Matched sitar voice — the SAME harmonic-resolved plucked-string model as
/// the tanpura (`TanpuraParams`), fitted to `sitar1.wav` (three C#4 plucks)
/// by `tools/sitar_iterate.py` and baked by `tools/sitar_bake_defaults.py`.
/// Its eventual home is the sympathetic-string layer, so the fit is ONE
/// pitch-invariant string timbre (mirrored onto all four model strings at
/// 280.4 Hz). Re-bake after a new match; `sitarMatchedVersion` keys the
/// AppController's UserDefaults persistence so a stale copy never shadows it.
public extension TanpuraParams {{
    /// Bumped every time a new matched sitar parameter set is baked.
    static let sitarMatchedVersion = {version}

    /// The matched sitar parameter set (decoded from the baked JSON below).
    static var sitar: TanpuraParams {{
        guard let data = sitarBakedJSON.data(using: .utf8),
              let params = try? JSONDecoder().decode(TanpuraParams.self,
                                                     from: data) else {{
            return TanpuraParams()
        }}
        return params
    }}

    private static let sitarBakedJSON = #"""
{blob}
"""#
}}
'''
    with open(SWIFT, "w") as f:
        f.write(swift)
    print(f"wrote {SWIFT}  (sitarMatchedVersion {version})")


if __name__ == "__main__":
    main()
