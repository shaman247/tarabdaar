#!/usr/bin/env python3
"""Bake a live full-chain match winner into `SoundPreset.swift` (`.swamViola`).

The sarangi's PLAYED voice (SWAM Violin) is a real-time-only AU, so its match
runs live (`tools/sarangi_iterate.py`) and the winner lands in
`auditions/sarangi/live_best.json` as a flat DIM→value dict. Unlike the sym
TARAB timbre (per-mode trims, baked into `SarangiParams.swift` from the offline
measurement by `sarangi_bake_defaults.py`), the Mac-side balance / EQ / FX /
SWAM-AU params + the searched sym macro SCALARS are set by the `.swamViola`
preset. This tool rewrites that one preset block from the winner so the deployed
sound reproduces the matched render — no error-prone hand-transcription.

What it rewrites in the `case .swamViola:` block:
  - sym macro scalar overrides (the `// BAKE:sym-macros:` block):
    symHarmonicFalloff / symDecay / symDampingTilt / symInharmonicity /
    symPartialCount
  - scalars: voiceMix, reverbMix
  - the shared body `s.violaBody = [...]` and `s.postReverb = [...]` arrays
    (overlaying only the fields the match tuned; pinned widths/freqs preserved)
  - the searched SWAM ids in `s.hostedAUParams` (bow pos/press/noise, string
    resonance); the constant dry-room / vibrato-off ids are left as-is

The structural bypass values (symBodyDry=1, symRoomWetDB=-60, zeroed halo body
gains, postReverbEnabled, violaBodyEnabled) are NOT touched — they're part of
the dry-SWAM architecture, not the match.

  python3 tools/sarangi_bake_preset.py [auditions/sarangi/live_best.json]
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import sarangi_iterate as si   # noqa: E402  (DIMS + pinned for the merge)

REPO = si.REPO
SWIFT = os.path.join(REPO, "TarabdaarMac", "SoundPreset.swift")
DEFAULT_IN = os.path.join(si.SDIR, "live_best.json")

# DIM name → Swift `s.<field>` scalar assignment in the swamViola block.
SCALARS = {
    "symHarmonicFalloff": "symHarmonicFalloff",
    "symDecay": "symDecay",
    "symDampingTilt": "symDampingTilt",
    "symInharmonicity": "symInharmonicity",
    "symPartialCount": "symPartialCount",
    "symExciteDrive": "symExciteDrive",
    "symExciteMix": "symExciteMix",
    "symExciteCrossover": "symExciteCrossover",
    "voiceMix": "voiceMix",
    "reverbMix": "reverbMix",
}

# The 4 SWAM ids the match SEARCHES (bow timbre + string resonance). The rest of
# hostedAUParams (vibrato-off, the dry-room block) is constant and left alone.
SWAM_SEARCHED = ["1013107514", "1484578252", "574719741", "1958189775"]


def fmt(v):
    """Compact Swift Double literal."""
    s = f"{float(v):.6g}"
    return s


def load_winner(path):
    import json
    d = json.load(open(path))
    return d.get("params", d)


def rewrite_scalar(txt, field, value):
    pat = re.compile(r"(s\." + re.escape(field) + r"\s*=\s*)-?[\d.]+(?:[eE][-+]?\d+)?")
    new, n = pat.subn(lambda m: m.group(1) + fmt(value), txt, count=1)
    if n == 0:
        print(f"  ! scalar s.{field} not found (skipped)")
    return new


def rewrite_band_array(txt, swift_array, dim_prefix, n_bands, merged):
    """Overlay `<dim_prefix>{i}.{freq|gainDB|widthOct}` from `merged` onto the
    existing `s.<swift_array> = [ ViolaBodyBand(...) x N ]` literal, preserving
    any field the match didn't tune."""
    block_pat = re.compile(r"(s\." + re.escape(swift_array) +
                           r"\s*=\s*\[)(.*?)(\n\s*\])", re.S)
    m = block_pat.search(txt)
    if not m:
        print(f"  ! array s.{swift_array} not found (skipped)")
        return txt
    band_pat = re.compile(
        r"ViolaBodyBand\(freq:\s*(-?[\d.eE+-]+),\s*gainDB:\s*(-?[\d.eE+-]+),"
        r"\s*widthOct:\s*(-?[\d.eE+-]+)\)")
    bands = band_pat.findall(m.group(2))
    if len(bands) != n_bands:
        print(f"  ! s.{swift_array}: expected {n_bands} bands, found {len(bands)}")
        return txt
    out = []
    for i, (f, g, w) in enumerate(bands):
        vals = {"freq": float(f), "gainDB": float(g), "widthOct": float(w)}
        for field in vals:
            key = f"{dim_prefix}{i}.{field}"
            if key in merged:
                vals[field] = float(merged[key])
        out.append(f"                ViolaBodyBand(freq: {fmt(vals['freq'])}, "
                   f"gainDB: {fmt(vals['gainDB'])}, widthOct: {fmt(vals['widthOct'])}),")
    new_block = m.group(1) + "\n" + "\n".join(out) + m.group(3)
    return txt[:m.start()] + new_block + txt[m.end():]


def rewrite_hosted(txt, merged):
    for sid in SWAM_SEARCHED:
        key = f"swam.{sid}"
        if key not in merged:
            continue
        pat = re.compile(r'("' + sid + r'":\s*)-?[\d.]+(?:[eE][-+]?\d+)?')
        txt, n = pat.subn(lambda m: m.group(1) + fmt(merged[key]), txt, count=1)
        if n == 0:
            print(f"  ! hostedAUParams id {sid} not found (skipped)")
    return txt


def main():
    in_path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_IN
    if not os.path.exists(in_path):
        raise SystemExit(f"no winner file: {in_path}")
    params = load_winner(in_path)
    _, pinned = si.load_seed()
    merged = {**pinned, **params}   # same merge build_score uses

    txt = open(SWIFT).read()
    # Operate only on the swamViola case so we never touch the State defaults.
    case_pat = re.compile(r"(case \.swamViola:\n)(.*?)(\n            return s\n)", re.S)
    cm = case_pat.search(txt)
    if not cm:
        raise SystemExit("could not locate `case .swamViola:` block")
    block = cm.group(2)

    print(f"[bake-preset] {in_path} -> {os.path.relpath(SWIFT, REPO)}")
    for dim, field in SCALARS.items():
        if dim in merged:
            block = rewrite_scalar(block, field, merged[dim])
            print(f"  s.{field:20s} = {fmt(merged[dim])}")
    block = rewrite_band_array(block, "violaBody", "violaBody", 4, merged)
    block = rewrite_band_array(block, "postReverb", "postEQ", 3, merged)
    block = rewrite_hosted(block, merged)
    for sid in SWAM_SEARCHED:
        if f"swam.{sid}" in merged:
            print(f"  hostedAU[{sid}] = {fmt(merged[f'swam.{sid}'])}")

    new_txt = txt[:cm.start(2)] + block + txt[cm.end(2):]
    tmp = SWIFT + ".tmp"
    with open(tmp, "w") as f:
        f.write(new_txt)
    os.replace(tmp, SWIFT)
    print("[bake-preset] done — rebuild TarabdaarMac and A/B against the materialized winner.")


if __name__ == "__main__":
    main()
