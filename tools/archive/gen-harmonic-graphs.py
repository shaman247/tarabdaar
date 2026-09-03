#!/usr/bin/env python3
"""Generate a self-contained HTML page graphing each harmonic's amplitude
over time for the main voice (drive) vs the sympathetic voice, so the
per-harmonic onset/peak timing can be inspected.

Runs the StarpadDSP harness to emit the data, then embeds it in an HTML
file with inline-SVG small-multiple charts (one per harmonic).

Usage:
    python3 tools/gen-harmonic-graphs.py [output.html]
"""
import json
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PKG = REPO / "Packages" / "StarpadDSP"
OUT = Path(sys.argv[1]) if len(sys.argv) > 1 else REPO / "tools" / "sym-harmonics.html"
DATA = Path("/tmp/tarabdaar-sym-harmonics.json")


def collect():
    print("Running harness to emit harmonic data…", file=sys.stderr)
    proc = subprocess.run(
        ["swift", "test", "--package-path", str(PKG),
         "--filter", "testEmitHarmonicEnvelopeJSON"],
        capture_output=True, text=True)
    if not DATA.exists():
        sys.exit("Harness did not write " + str(DATA) + ":\n"
                 + (proc.stdout + proc.stderr)[-2000:])
    return json.loads(DATA.read_text())


def chart(t, main, sym, k, f0, peak, w=420, h=150, pad=30):
    tmax = t[-1] if t else 1.0
    ymax = max(max(main + sym) * 1.08, 1e-9)

    def X(tt):
        return pad + (tt / tmax) * (w - 1.4 * pad)

    def Y(yy):
        return h - pad - (yy / ymax) * (h - 1.7 * pad)

    def path(ys):
        return "M " + " L ".join(f"{X(t[i]):.1f} {Y(ys[i]):.1f}" for i in range(len(ys)))

    grid = []
    for frac in (0.0, 0.5, 1.0):
        yy = Y(ymax * frac)
        grid.append(f'<line x1="{pad}" y1="{yy:.1f}" x2="{w-0.4*pad:.1f}" y2="{yy:.1f}" class="grid"/>')
    # x ticks every 0.2s
    tt = 0.0
    while tt <= tmax + 1e-6:
        xx = X(tt)
        grid.append(f'<line x1="{xx:.1f}" y1="{pad}" x2="{xx:.1f}" y2="{h-pad}" class="grid"/>')
        grid.append(f'<text x="{xx:.1f}" y="{h-pad+12:.1f}" class="xlab">{tt:.1f}</text>')
        tt += 0.2
    # peak markers (vertical dashed)
    mark = (f'<line x1="{X(peak["mainPkT"]):.1f}" y1="{pad}" x2="{X(peak["mainPkT"]):.1f}" '
            f'y2="{h-pad}" class="mpk"/>'
            f'<line x1="{X(peak["symPkT"]):.1f}" y1="{pad}" x2="{X(peak["symPkT"]):.1f}" '
            f'y2="{h-pad}" class="spk"/>')
    lag = (peak["symPkT"] - peak["mainPkT"]) * 1000
    return f'''<svg viewBox="0 0 {w} {h}" class="chart">
  <rect x="{pad}" y="{pad}" width="{w-1.4*pad:.0f}" height="{h-1.7*pad:.0f}" class="plot"/>
  {''.join(grid)}{mark}
  <path d="{path(main)}" class="main"/>
  <path d="{path(sym)}" class="sym"/>
  <text x="{pad+4}" y="{pad-8}" class="ct">h{k} · {f0*k:.0f} Hz · sym peak {peak["symPkT"]:.2f}s (lag {lag:+.0f} ms)</text>
</svg>'''


def case_html(c):
    charts = "\n".join(
        chart(c["t"], c["main"][k - 1], c["sym"][k - 1], k, c["f0"], c["peaks"][k - 1])
        for k in range(1, len(c["main"]) + 1))
    return f'<h2>{c["label"]}</h2>\n<div class="grid-wrap">{charts}</div>'


def main():
    data = collect()
    body = "\n".join(case_html(c) for c in data)
    html = f'''<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<title>Per-harmonic amplitude — main voice vs sympathetic</title>
<style>
  body {{ font:14px -apple-system, system-ui, sans-serif; background:#0e0f13;
         color:#e6e7ea; margin:0; padding:24px 28px; }}
  h1 {{ font-size:20px; margin:0 0 4px; }}
  h2 {{ font-size:15px; margin:22px 0 8px; color:#cdd2da; }}
  p.sub {{ color:#9aa0ab; margin:0 0 8px; max-width:900px; }}
  .legend span {{ margin-right:18px; }}
  .swatch {{ display:inline-block; width:22px; height:3px; vertical-align:middle; margin-right:6px; }}
  .grid-wrap {{ display:grid; grid-template-columns:repeat(2,minmax(360px,1fr)); gap:10px; max-width:1000px; }}
  .chart {{ width:100%; background:#15171d; border-radius:6px; }}
  .plot {{ fill:#1b1e26; }}
  .grid {{ stroke:#2a2e38; stroke-width:1; }}
  .main {{ fill:none; stroke:#4ea1ff; stroke-width:1.6; }}
  .sym  {{ fill:none; stroke:#ff9d42; stroke-width:1.6; }}
  .mpk {{ stroke:#4ea1ff; stroke-width:1; stroke-dasharray:3 3; opacity:.6; }}
  .spk {{ stroke:#ff9d42; stroke-width:1; stroke-dasharray:3 3; opacity:.6; }}
  .ct {{ fill:#aeb4bf; font-size:10.5px; }}
  .xlab {{ fill:#8b919c; font-size:9px; text-anchor:middle; }}
</style></head><body>
<h1>Per-harmonic amplitude over time — main voice vs sympathetic</h1>
<p class="sub">Sliding-window Goertzel (40&nbsp;ms window, 5&nbsp;ms hop) at each harmonic
of C3. Absolute amplitude (each chart auto-scaled). Dashed verticals mark each
trace's peak time. Generated from <code>SymVsTanpuraC3.testEmitHarmonicEnvelopeJSON</code>.</p>
<div class="legend">
  <span><span class="swatch" style="background:#4ea1ff"></span>Main voice (drive)</span>
  <span><span class="swatch" style="background:#ff9d42"></span>Sympathetic</span>
</div>
{body}
</body></html>'''
    OUT.write_text(html)
    print(f"Wrote {OUT}", file=sys.stderr)


if __name__ == "__main__":
    main()
