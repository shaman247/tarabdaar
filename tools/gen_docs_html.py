#!/usr/bin/env python3
"""Tarabdaar documentation site generator (2026-07-24).

Renders every docs/*.md into docs/html/<page>.html with a fixed left
sidebar: the page list (curated order, extras appended) plus the current
page's section headings. Dependency-free — a compact markdown converter
tuned to this corpus (headings, lists, tables, fenced code, blockquotes,
bold/italic/code/links). Run by tools/build-mac.sh on every build, so the
HTML always tracks the markdown (including the auto-generated
parameters.md). DO NOT hand-edit docs/html/*.

Usage: python3 tools/gen_docs_html.py   (from anywhere; paths are
repo-relative to this script)
"""

import html
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOCS = os.path.join(ROOT, "docs")
OUT = os.path.join(DOCS, "html")

# Curated reading order (CLAUDE.md's docs list); extra pages appended.
ORDER = [
    "overview", "playing-guide", "architecture", "sarangi", "tanpura-voice",
    "sitar-voice", "fret-pad", "glide-system", "scales-and-tuning",
    "midi-and-audio", "sensors", "sound-design", "fx", "ui-layout",
    "parameters", "config-reference", "packaging", "tech-debt",
]

CSS = """
:root { color-scheme: dark; }
* { box-sizing: border-box; }
body { margin: 0; background: #16181d; color: #d6d9de;
       font: 15px/1.55 -apple-system, "Helvetica Neue", sans-serif; }
a { color: #7fb4e6; text-decoration: none; }
a:hover { text-decoration: underline; }
.layout { display: flex; min-height: 100vh; }
nav { width: 250px; flex: none; background: #101216; padding: 18px 14px;
      border-right: 1px solid #262a31; position: sticky; top: 0;
      height: 100vh; overflow-y: auto; }
nav .site { font-weight: 700; font-size: 15px; color: #e8eaee;
            margin-bottom: 12px; }
nav a.page { display: block; padding: 3px 8px; border-radius: 5px;
             color: #aeb4bd; font-size: 13.5px; }
nav a.page:hover { background: #1c2027; text-decoration: none; }
nav a.page.current { background: #23303f; color: #dce7f3; font-weight: 600; }
nav a.section { display: block; padding: 1px 8px 1px 22px; color: #7d8590;
                font-size: 12.5px; }
nav a.section:hover { color: #aeb4bd; text-decoration: none; }
main { flex: 1; min-width: 0; padding: 30px 44px 80px; max-width: 900px; }
h1, h2, h3, h4 { color: #e8eaee; line-height: 1.25; }
h1 { font-size: 26px; border-bottom: 1px solid #2a2f37;
     padding-bottom: 8px; }
h2 { font-size: 20px; margin-top: 34px; border-bottom: 1px solid #23272e;
     padding-bottom: 5px; }
h3 { font-size: 16.5px; margin-top: 26px; }
h4 { font-size: 15px; }
code { background: #22262d; border-radius: 4px; padding: 1px 5px;
       font: 12.5px/1.5 "SF Mono", Menlo, monospace; color: #e3e6ea; }
pre { background: #0e1013; border: 1px solid #23272e; border-radius: 8px;
      padding: 12px 14px; overflow-x: auto; }
pre code { background: none; padding: 0; }
table { border-collapse: collapse; margin: 14px 0; display: block;
        overflow-x: auto; max-width: 100%; }
th, td { border: 1px solid #2a2f37; padding: 6px 10px; text-align: left;
         vertical-align: top; font-size: 13.5px; }
th { background: #1c2027; color: #e0e3e8; }
tr:nth-child(even) td { background: #191c22; }
blockquote { margin: 14px 0; padding: 8px 16px; border-left: 3px solid
             #4a586b; background: #1a1e25; border-radius: 0 6px 6px 0;
             color: #b8bec7; }
hr { border: none; border-top: 1px solid #2a2f37; margin: 26px 0; }
li { margin: 3px 0; }
img { max-width: 100%; }
"""


def slugify(text):
    t = re.sub(r"[`*_]", "", text).strip().lower()
    t = re.sub(r"[^\w\- ]", "", t)
    return re.sub(r"\s+", "-", t).strip("-")


def rewrite_href(url):
    """Point relative .md links at the generated .html twins."""
    if re.match(r"^[a-z]+://", url) or url.startswith("#"):
        return url
    m = re.match(r"^(?:docs/)?([\w\-]+)\.md(#.*)?$", url)
    if m:
        return m.group(1) + ".html" + (m.group(2) or "")
    return url


CODE_TOKEN = "\x00CODE%d\x00"


def inline(text):
    """Inline markdown on an unescaped source line."""
    # protect code spans before escaping/styling
    codes = []

    def stash(m):
        codes.append(m.group(1))
        return CODE_TOKEN % (len(codes) - 1)

    text = re.sub(r"`([^`]+)`", stash, text)
    text = html.escape(text, quote=False)
    # Parameter descriptions use explicit breaks inside Markdown table cells.
    # Permit only this attribute-free tag; other raw HTML stays escaped.
    text = re.sub(r"&lt;br\s*/?&gt;", "<br>", text)
    # links (no nested brackets in this corpus)
    text = re.sub(
        r"\[([^\]]+)\]\(([^)\s]+)\)",
        lambda m: '<a href="%s">%s</a>'
        % (html.escape(rewrite_href(m.group(2)), quote=True), m.group(1)),
        text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"(?<![\w*])\*([^*\n]+)\*(?![\w*])", r"<em>\1</em>", text)
    for i, c in enumerate(codes):
        text = text.replace(CODE_TOKEN % i,
                            "<code>%s</code>" % html.escape(c, quote=False))
    return text


def convert(md):
    """Markdown → (html body, [(level, title, anchor), ...])."""
    lines = md.splitlines()
    out = []
    headings = []
    i = 0
    list_stack = []          # open list indents

    def close_lists(to_indent=-1):
        while list_stack and list_stack[-1] >= to_indent:
            out.append("</ul>")
            list_stack.pop()

    n = len(lines)
    while i < n:
        line = lines[i]

        # fenced code
        if line.strip().startswith("```"):
            close_lists(0)
            i += 1
            block = []
            while i < n and not lines[i].strip().startswith("```"):
                block.append(lines[i])
                i += 1
            i += 1
            out.append("<pre><code>%s</code></pre>"
                       % html.escape("\n".join(block), quote=False))
            continue

        # HTML comment passthrough (the AUTO-GENERATED banner)
        if line.lstrip().startswith("<!--"):
            block = [line]
            while "-->" not in block[-1] and i + 1 < n:
                i += 1
                block.append(lines[i])
            out.append("\n".join(block))
            i += 1
            continue

        # heading
        m = re.match(r"^(#{1,6})\s+(.*)$", line)
        if m:
            close_lists(0)
            level = len(m.group(1))
            title = m.group(2).strip()
            anchor = slugify(title)
            headings.append((level, title, anchor))
            out.append('<h%d id="%s">%s</h%d>'
                       % (level, anchor, inline(title), level))
            i += 1
            continue

        # horizontal rule
        if re.match(r"^\s*---+\s*$", line):
            close_lists(0)
            out.append("<hr>")
            i += 1
            continue

        # table
        if line.lstrip().startswith("|") and i + 1 < n \
                and re.match(r"^\s*\|[\s:\-|]+\|\s*$", lines[i + 1]):
            close_lists(0)
            def cells(row):
                return [c.strip() for c in row.strip().strip("|").split("|")]
            out.append("<table>")
            out.append("<tr>%s</tr>" % "".join(
                "<th>%s</th>" % inline(c) for c in cells(line)))
            i += 2
            while i < n and lines[i].lstrip().startswith("|"):
                out.append("<tr>%s</tr>" % "".join(
                    "<td>%s</td>" % inline(c) for c in cells(lines[i])))
                i += 1
            out.append("</table>")
            continue

        # blockquote
        if line.lstrip().startswith(">"):
            close_lists(0)
            block = []
            while i < n and lines[i].lstrip().startswith(">"):
                block.append(re.sub(r"^\s*>\s?", "", lines[i]))
                i += 1
            inner, _ = convert("\n".join(block))
            out.append("<blockquote>%s</blockquote>" % inner)
            continue

        # list item (unordered or ordered — rendered uniformly)
        m = re.match(r"^(\s*)(?:[-*]|\d+\.)\s+(.*)$", line)
        if m:
            indent = len(m.group(1))
            content = [m.group(2)]
            i += 1
            # continuation lines: deeper-indented non-item text
            while i < n and lines[i].strip() \
                    and not re.match(r"^\s*(?:[-*]|\d+\.|#|```|\||>)", lines[i]) \
                    and (len(lines[i]) - len(lines[i].lstrip())) > indent:
                content.append(lines[i].strip())
                i += 1
            if not list_stack or indent > list_stack[-1]:
                out.append("<ul>")
                list_stack.append(indent)
            else:
                while len(list_stack) > 1 and indent < list_stack[-1]:
                    out.append("</ul>")
                    list_stack.pop()
            out.append("<li>%s</li>" % inline(" ".join(content)))
            continue

        # blank
        if not line.strip():
            close_lists(0)
            i += 1
            continue

        # paragraph
        close_lists(0)
        block = [line]
        i += 1
        while i < n and lines[i].strip() \
                and not re.match(r"^\s*(?:[-*] |\d+\. |#|```|\||>)", lines[i]):
            block.append(lines[i])
            i += 1
        out.append("<p>%s</p>" % inline(" ".join(b.strip() for b in block)))

    close_lists(0)
    return "\n".join(out), headings


def page_title(md, slug):
    m = re.search(r"^#\s+(.*)$", md, re.M)
    if m:
        return re.sub(r"[`*]", "", m.group(1)).strip()
    return slug.replace("-", " ").title()


def main():
    pages = sorted(
        f[:-3] for f in os.listdir(DOCS)
        if f.endswith(".md"))
    ordered = [p for p in ORDER if p in pages] \
        + [p for p in pages if p not in ORDER]

    sources = {}
    titles = {}
    for slug in ordered:
        with open(os.path.join(DOCS, slug + ".md"), encoding="utf-8") as f:
            sources[slug] = f.read()
        titles[slug] = page_title(sources[slug], slug)

    os.makedirs(OUT, exist_ok=True)
    for slug in ordered:
        body, headings = convert(sources[slug])
        nav = ['<div class="site"><a href="index.html" '
               'style="color:inherit">Tarabdaar Docs</a></div>']
        for p in ordered:
            cur = " current" if p == slug else ""
            nav.append('<a class="page%s" href="%s.html">%s</a>'
                       % (cur, p, html.escape(titles[p])))
            if p == slug:
                for level, title, anchor in headings:
                    if level == 2:
                        nav.append('<a class="section" href="#%s">%s</a>'
                                   % (anchor, html.escape(
                                       re.sub(r"[`*]", "", title))))
        doc = ("<!DOCTYPE html>\n"
               "<!-- AUTO-GENERATED by tools/gen_docs_html.py from "
               "docs/%s.md — DO NOT EDIT. -->\n"
               '<html lang="en"><head><meta charset="utf-8">\n'
               '<meta name="viewport" content="width=device-width, '
               'initial-scale=1">\n'
               "<title>%s — Tarabdaar</title>\n<style>%s</style></head>\n"
               '<body><div class="layout"><nav>%s</nav>\n'
               "<main>%s</main></div></body></html>\n"
               % (slug, html.escape(titles[slug]), CSS,
                  "\n".join(nav), body))
        with open(os.path.join(OUT, slug + ".html"), "w",
                  encoding="utf-8") as f:
            f.write(doc)

    # index = the overview page under the canonical landing name
    first = ordered[0]
    with open(os.path.join(OUT, first + ".html"), encoding="utf-8") as f:
        landing = f.read()
    with open(os.path.join(OUT, "index.html"), "w", encoding="utf-8") as f:
        f.write(landing)

    print("gen_docs_html: %d pages -> %s"
          % (len(ordered), os.path.relpath(OUT, ROOT)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
