"""Contracts for documentation links after rendering into docs/html."""

import importlib.util
from html import unescape
from pathlib import Path
import re
import tempfile
import unittest
from unittest.mock import patch
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("gen_docs_html", ROOT / "tools/gen_docs_html.py")
docs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(docs)


class DocumentationLinksTests(unittest.TestCase):
    def test_rendered_link_preserves_query_parameters(self):
        rendered = docs.inline("[target](sensors.md?x=1&y=2)")
        href = re.search(r'href="([^"]+)"', rendered).group(1)
        self.assertEqual(unescape(href), "sensors.html?x=1&y=2")

    def test_heading_anchors_match_markdown_links(self):
        self.assertEqual(docs.slugify("Scale sync (Mac → iPad)"), "scale-sync-mac--ipad")

    def test_relocated_links_keep_their_targets(self):
        cases = {
            "sensors.md#binding-model": "sensors.html#binding-model",
            "./sensors.md": "sensors.html",
            "history/README.md": "../history/README.md",
            "../tools/release-mac.sh": "../../tools/release-mac.sh",
            "../AGENTS.md": "../../AGENTS.md",
            "image.png?size=2#detail": "../image.png?size=2#detail",
            "#section": "#section",
            "https://example.com/a.md": "https://example.com/a.md",
            "mailto:example@example.com": "mailto:example@example.com",
            "//example.com/a.md": "//example.com/a.md",
        }
        for source, expected in cases.items():
            with self.subTest(source=source):
                self.assertEqual(docs.rewrite_href(source), expected)

    def test_current_reference_links_resolve(self):
        self.check_reference_links(ROOT)

    def test_links_resolve_before_html_directory_exists(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "docs/history").mkdir(parents=True)
            (root / "tools").mkdir()
            (root / "docs/history/README.md").write_text("# Archive\n")
            (root / "tools/example.sh").write_text("exit 0\n")
            (root / "docs/index.md").write_text(
                "# Index\n[history](history/README.md)\n"
                "[script](../tools/example.sh)\n[section](#index)\n")
            self.assertFalse((root / "docs/html").exists())
            with patch.object(docs, "DOCS", str(root / "docs")):
                self.check_reference_links(root)
            self.assertFalse((root / "docs/html").exists())

    def check_reference_links(self, root):
        sources = {p.stem: p.read_text() for p in (root / "docs").glob("*.md")}
        rendered = {slug: docs.convert(source) for slug, source in sources.items()}
        anchors = {slug: {anchor for _, _, anchor in headings}
                   for slug, (_, headings) in rendered.items()}
        for slug, (body, _) in rendered.items():
            for target in re.findall(r'(?:href|src)="([^"]+)"', body):
                parts = urlsplit(unescape(target))
                if parts.scheme or parts.netloc or parts.path.startswith("/"):
                    continue
                with self.subTest(page=slug, target=target):
                    path = unquote(parts.path)
                    if not path:
                        self.assertIn(unquote(parts.fragment), anchors[slug])
                    elif Path(path).parent == Path(".") and path.endswith(".html"):
                        page = Path(path).stem
                        self.assertIn(page, sources)
                        if parts.fragment:
                            self.assertIn(unquote(parts.fragment), anchors[page])
                    else:
                        self.assertTrue((root / "docs/html" / path).resolve().exists())


if __name__ == "__main__":
    unittest.main()
