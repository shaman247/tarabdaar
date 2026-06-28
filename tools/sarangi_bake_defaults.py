#!/usr/bin/env python3
"""Bake a matched sarangi tarab voice into `SarangiParams.swift`.

Reads a fitted `TanpuraParams` JSON (default: auditions/sarangi/init.json),
mirrors the single fitted tarab string onto all four template strings, and
rewrites `Packages/StarpadDSP/Sources/StarpadDSP/SarangiParams.swift` as an
embedded-JSON `TanpuraParams.sarangi` (the form `SitarParams.swift` uses),
bumping `sarangiMatchedVersion`.

Unlike the tanpura/sitar bakes there is NO peak-normalization render: the sym
resonator's absolute level is set by `resonatorMasterGain` in the Swift engine,
so these params carry only the TIMBRE (relative per-mode gains, decays, body).
"""

import argparse
import json
import os
import re

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SWIFT = os.path.join(REPO, "Packages", "StarpadDSP", "Sources", "StarpadDSP",
                     "SarangiParams.swift")
DEFAULT_IN = os.path.join(REPO, "auditions", "sarangi", "init.json")


def normalize(p):
    """Strip bookkeeping keys, pad trim arrays to 64, mirror string 0 → all 4."""
    for k in [k for k in list(p) if k.startswith("_")]:
        del p[k]
    s0 = p["strings"][0]
    s0["gainTrimDB"] = (s0.get("gainTrimDB", []) + [0.0] * 64)[:64]
    s0["peakTrim"] = (s0.get("peakTrim", []) + [1.0] * 64)[:64]
    s0["decayTrim"] = (s0.get("decayTrim", []) + [1.0] * 64)[:64]
    p["strings"] = [json.loads(json.dumps(s0)) for _ in range(4)]
    p.setdefault("masterGain", 1.0)
    return p


def current_version():
    txt = open(SWIFT).read()
    m = re.search(r"sarangiMatchedVersion\s*=\s*(\d+)", txt)
    return int(m.group(1)) if m else 1


def write_swift(p, version):
    blob = json.dumps(p, indent=2, sort_keys=True)
    out = f'''import Foundation

/// Matched **sarangi** sympathetic-string (tarab) timbre — fitted to
/// `sarangi1.wav` (isolated tarab plucks) by `tools/sarangi_match.py` and
/// baked by `tools/sarangi_bake_defaults.py`. Reuses the `TanpuraParams`
/// container as a parameter bag for the driven modal resonator
/// (`SarangiResonator`): `gainTrimDB` → per-mode gain, `decayTrim` → per-mode
/// decay (→ Q), plus the `falloff` / `decay` / `dampTilt` / `inharmonicity`
/// / `sub*` laws and the `body` formants. The pluck-only fields are unused.
///
/// There is no level here: the absolute halo level is `resonatorMasterGain`
/// in `OfflineEngine`. These are timbre only. Re-bake after a new fit;
/// `sarangiMatchedVersion` keys the Mac's UserDefaults persistence.
public extension TanpuraParams {{
    /// Bumped every time a new matched sarangi parameter set is baked.
    static let sarangiMatchedVersion = {version}

    /// The matched sarangi tarab timbre (decoded from the baked JSON below).
    static var sarangi: TanpuraParams {{
        guard let data = sarangiBakedJSON.data(using: .utf8),
              let params = try? JSONDecoder().decode(TanpuraParams.self,
                                                     from: data) else {{
            return TanpuraParams()
        }}
        return params
    }}

    private static let sarangiBakedJSON = #"""
{blob}
"""#
}}
'''
    tmp = SWIFT + ".tmp"
    with open(tmp, "w") as f:
        f.write(out)
    os.replace(tmp, SWIFT)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("params", nargs="?", default=DEFAULT_IN)
    ap.add_argument("--bump", action="store_true",
                    help="increment sarangiMatchedVersion")
    args = ap.parse_args()
    p = normalize(json.load(open(args.params)))
    version = current_version() + (1 if args.bump else 0)
    write_swift(p, version)
    s = p["strings"][0]
    print(f"baked {args.params} -> SarangiParams.swift (v{version})")
    print(f"  falloff {s['falloff']}  decay {s['decay']}  dampTilt {s['dampTilt']}"
          f"  harmonicCount {p['harmonicCount']}")
    print(f"  body {p['body']}")
    print("  rebuild: swift build -c release --package-path Packages/StarpadDSP")


if __name__ == "__main__":
    main()
