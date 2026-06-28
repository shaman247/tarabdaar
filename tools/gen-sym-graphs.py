#!/usr/bin/env python3
"""Generate a self-contained HTML page graphing the main-voice vs
sympathetic-voice amplitude envelopes for staccato / 1 s / 10 s notes.

Runs the StarpadDSP harness to emit the envelope data, then embeds it in
an HTML file with inline-SVG charts (no network / CDN needed).

Usage:
    python3 tools/gen-sym-graphs.py [output.html]
"""
import json
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PKG = REPO / "Packages" / "StarpadDSP"
OUT = Path(sys.argv[1]) if len(sys.argv) > 1 else REPO / "tools" / "sym-envelopes.html"


DATA = Path("/tmp/starpad-sym-envelopes.json")


def collect():
    print("Running harness to emit envelope data…", file=sys.stderr)
    proc = subprocess.run(
        ["swift", "test", "--package-path", str(PKG),
         "--filter", "testEmitEnvelopeJSON"],
        capture_output=True, text=True)
    if not DATA.exists():
        sys.exit("Harness did not write " + str(DATA) + ":\n"
                 + (proc.stdout + proc.stderr)[-2000:])
    return json.loads(DATA.read_text())


def svg_chart(case, w=900, h=300, pad=44):
    """One overlaid line chart: main (blue) vs sym (orange), each ÷ its
    hold level so they overlay around 1.0."""
    t = case["t"]
    mainH = case["mainHold"] or 1.0
    symH = case["symHold"] or 1.0
    main = [v / mainH for v in case["main"]]
    sym = [v / symH for v in case["sym"]]
    tmax = t[-1] if t else 1.0
    ymax = max(1.6, max(main + sym) * 1.05)

    def X(tt):
        return pad + (tt / tmax) * (w - 2 * pad)

    def Y(yy):
        return h - pad - (yy / ymax) * (h - 2 * pad)

    def path(ys):
        return "M " + " L ".join(f"{X(t[i]):.1f} {Y(ys[i]):.1f}" for i in range(len(ys)))

    # gridlines
    grid = []
    yticks = [v / 4 for v in range(0, int(ymax * 4) + 1)]
    for yt in yticks:
        if yt > ymax:
            continue
        yy = Y(yt)
        grid.append(f'<line x1="{pad}" y1="{yy:.1f}" x2="{w - pad}" y2="{yy:.1f}" '
                    f'class="grid"/>')
        grid.append(f'<text x="{pad - 6}" y="{yy + 4:.1f}" class="ylab">{yt:.2f}</text>')
    # x ticks
    nticks = 6
    for k in range(nticks + 1):
        tt = tmax * k / nticks
        xx = X(tt)
        grid.append(f'<line x1="{xx:.1f}" y1="{pad}" x2="{xx:.1f}" y2="{h - pad}" '
                    f'class="grid"/>')
        grid.append(f'<text x="{xx:.1f}" y="{h - pad + 16:.1f}" class="xlab">{tt:.2f}s</text>')
    # reference line at 1.0 (the hold level)
    grid.append(f'<line x1="{pad}" y1="{Y(1.0):.1f}" x2="{w - pad}" y2="{Y(1.0):.1f}" '
                f'class="ref"/>')

    return f'''<svg viewBox="0 0 {w} {h}" class="chart">
  <rect x="{pad}" y="{pad}" width="{w - 2 * pad}" height="{h - 2 * pad}" class="plot"/>
  {''.join(grid)}
  <path d="{path(main)}" class="main"/>
  <path d="{path(sym)}" class="sym"/>
  <text x="{w/2:.0f}" y="20" class="title">{case["label"]}</text>
</svg>'''


def main():
    data = collect()
    charts = "\n".join(svg_chart(c) for c in data)
    html = f'''<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<title>Sympathetic vs Main Voice — amplitude over time</title>
<style>
  body {{ font: 14px -apple-system, system-ui, sans-serif; background:#0e0f13;
         color:#e6e7ea; margin:0; padding:28px 32px; }}
  h1 {{ font-size:20px; margin:0 0 4px; }}
  p.sub {{ color:#9aa0ab; margin:0 0 20px; max-width:900px; }}
  .legend {{ margin:0 0 18px; }}
  .legend span {{ margin-right:18px; }}
  .swatch {{ display:inline-block; width:22px; height:3px; vertical-align:middle;
             margin-right:6px; }}
  .chart {{ width:100%; max-width:900px; display:block; margin:0 0 26px;
            background:#15171d; border-radius:8px; }}
  .plot {{ fill:#1b1e26; }}
  .grid {{ stroke:#2a2e38; stroke-width:1; }}
  .ref  {{ stroke:#4b5566; stroke-width:1; stroke-dasharray:4 4; }}
  .main {{ fill:none; stroke:#4ea1ff; stroke-width:2; }}
  .sym  {{ fill:none; stroke:#ff9d42; stroke-width:2; }}
  .title {{ fill:#e6e7ea; font-size:14px; font-weight:600; text-anchor:middle; }}
  .xlab,.ylab {{ fill:#8b919c; font-size:11px; }}
  .ylab {{ text-anchor:end; }} .xlab {{ text-anchor:middle; }}
  code {{ background:#22252e; padding:1px 5px; border-radius:4px; }}
</style></head><body>
<h1>Sympathetic voice vs main voice — amplitude over time</h1>
<p class="sub">Windowed-RMS amplitude envelopes (20&nbsp;ms window), each
normalized to its own hold level so the two overlay. The dashed line is that
hold level (1.0). A perfect match = the orange line tracks the blue one.
Generated from <code>SymVsTanpuraC3.testEmitEnvelopeJSON</code>.</p>
<div class="legend">
  <span><span class="swatch" style="background:#4ea1ff"></span>Main voice (drive)</span>
  <span><span class="swatch" style="background:#ff9d42"></span>Sympathetic voice</span>
</div>
{charts}
</body></html>'''
    OUT.write_text(html)
    print(f"Wrote {OUT}", file=sys.stderr)


if __name__ == "__main__":
    main()
