#!/usr/bin/env python3
"""Focused public-behavior tests for validate_html_site.py."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("validate_html_site.py")
CSP = (
    "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; "
    "base-uri 'none'; form-action 'none'"
)


def canonical_search_script() -> str:
    source = (SCRIPT.parent.parent / "src/render/renderers.cj").read_text(encoding="utf-8")
    marker = 'private let HTML_SEARCH_SCRIPT = """\n'
    literal = source.split(marker, 1)[1].split('\n"""', 1)[0]
    # The script's only Cangjie escape is the doubled backslash in /\s+/.
    # Decode it instead of treating source spelling as emitted bytes.
    return literal.replace("\\\\", "\\") + "\n"


class ValidateHtmlSiteTest(unittest.TestCase):
    def write_site(self, root: Path) -> None:
        index = (
            "<!doctype html><html><head>"
            f'<meta http-equiv="Content-Security-Policy" content="{CSP}">'
            "</head><body><main id=\"top\"><a href=\"#top\">top</a></main>"
            '<script defer src="search-index.js"></script>'
            '<script defer src="search.js"></script></body></html>'
        )
        (root / "index.html").write_text(index, encoding="utf-8", newline="\n")
        (root / "search.js").write_text(
            canonical_search_script(), encoding="utf-8", newline="\n"
        )
        search_text = json.dumps(
            {"schemaVersion": "cjdoc.search-index/4", "entries": []},
            separators=(",", ":"),
        )
        (root / "search-index.json").write_text(
            search_text + "\n", encoding="utf-8", newline="\n"
        )
        (root / "search-index.js").write_text(
            "globalThis.__CJDOC_SEARCH_INDEX__ = " + search_text + ";\n",
            encoding="utf-8", newline="\n",
        )

    def validate(self, root: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPT), str(root)],
            check=False,
            capture_output=True,
            text=True,
        )

    def test_accepts_well_formed_external_script_site(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_site(root)
            result = self.validate(root)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("validated 1 HTML pages", result.stdout)

    def test_canonical_search_arrow_up_starts_at_last_result(self) -> None:
        script = canonical_search_script()
        self.assertIn(
            "select(selected < 0 ? visible.length - 1 : selected - 1)", script
        )
        self.assertNotIn("select(selected - 1)", script)

    def test_canonical_search_disambiguates_duplicate_visible_labels(self) -> None:
        script = canonical_search_script()
        self.assertIn(
            "JSON.stringify([entry.packageName, entry.qualifiedName])", script
        )
        self.assertIn("ambiguousLabels.add(key)", script)
        self.assertIn(
            'ambiguousLabels.has(displayKey(entry)) ? " · " + entry.id : ""',
            script,
        )

    def test_canonical_script_exposes_all_theme_presets(self) -> None:
        script = canonical_search_script()
        for theme in ("system", "light", "dark", "paper", "ocean", "forest", "terminal", "violet"):
            with self.subTest(theme=theme):
                self.assertIn(f'["{theme}"', script)
        self.assertIn("themeToggle.before(picker)", script)
        self.assertIn('localStorage.setItem("cjdoc-theme", next)', script)

    def test_rejects_mismatched_real_tags(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_site(root)
            page = (root / "index.html").read_text(encoding="utf-8")
            (root / "index.html").write_text(
                page.replace("</main>", "</section>"), encoding="utf-8"
            )
            result = self.validate(root)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("mismatched end tag", result.stderr)

    def test_rejects_inline_style_and_non_exact_csp(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_site(root)
            page = (root / "index.html").read_text(encoding="utf-8")
            (root / "index.html").write_text(
                page.replace('<main id="top">', '<main id="top" style="color:red">'),
                encoding="utf-8",
            )
            result = self.validate(root)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("inline style attribute is forbidden", result.stderr)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_site(root)
            page = (root / "index.html").read_text(encoding="utf-8")
            (root / "index.html").write_text(
                page.replace("form-action 'none'", "form-action 'self'"),
                encoding="utf-8",
            )
            result = self.validate(root)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("expected one exact CSP", result.stderr)

    def test_rejects_duplicate_attributes_and_csp_outside_head(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_site(root)
            page = (root / "index.html").read_text(encoding="utf-8")
            (root / "index.html").write_text(
                page.replace('<main id="top">', '<main id="top" ID="other">'),
                encoding="utf-8",
            )
            result = self.validate(root)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("duplicate attribute 'id'", result.stderr)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_site(root)
            page = (root / "index.html").read_text(encoding="utf-8")
            meta = f'<meta http-equiv="Content-Security-Policy" content="{CSP}">'
            (root / "index.html").write_text(
                page.replace(meta, "").replace("<body>", "<body>" + meta),
                encoding="utf-8",
            )
            result = self.validate(root)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("CSP meta must be a direct child of head", result.stderr)

    def test_rejects_percent_encoded_dot_segments_before_resolution(self) -> None:
        encoded_paths = [
            "%2e%2e/outside.html",
            "%2E./outside.html",
            ".%2e/outside.html",
            "%2e/same.html",
            "safe%2f..%2foutside.html",
        ]
        for encoded_path in encoded_paths:
            with self.subTest(encoded_path=encoded_path), \
                    tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self.write_site(root)
                page = (root / "index.html").read_text(encoding="utf-8")
                (root / "index.html").write_text(
                    page.replace(
                        '<a href="#top">top</a>',
                        f'<a href="{encoded_path}">encoded</a>',
                    ),
                    encoding="utf-8",
                )
                result = self.validate(root)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("percent-encoded dot segment", result.stderr)

    def test_rejects_search_script_payload_drift(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_site(root)
            script = (root / "search-index.js").read_text(encoding="utf-8")
            (root / "search-index.js").write_text(
                script.replace("\"entries\":[]", "\"entries\":[],\"extra\":true"),
                encoding="utf-8",
            )
            result = self.validate(root)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("payload differs", result.stderr)

    def test_rejects_noncanonical_script_set_and_content(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_site(root)
            (root / "extra.js").write_text("// extra\n", encoding="utf-8")
            result = self.validate(root)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("canonical script set", result.stderr)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_site(root)
            with (root / "search.js").open("a", encoding="utf-8") as stream:
                stream.write("// drift\n")
            result = self.validate(root)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("differs from the canonical", result.stderr)

    def test_rejects_script_before_csp_or_unexpected_reference(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_site(root)
            page = (root / "index.html").read_text(encoding="utf-8")
            script = '<script defer src="search-index.js"></script>'
            page = page.replace(script, "", 1).replace("<head>", "<head>" + script)
            (root / "index.html").write_text(page, encoding="utf-8")
            result = self.validate(root)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("CSP must precede", result.stderr)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_site(root)
            page = (root / "index.html").read_text(encoding="utf-8")
            (root / "index.html").write_text(
                page.replace('src="search.js"', 'src="./search.js"'),
                encoding="utf-8",
            )
            result = self.validate(root)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("canonical script references", result.stderr)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_site(root)
            page = (root / "index.html").read_text(encoding="utf-8")
            (root / "index.html").write_text(
                page.replace(
                    '<script defer src="search.js">',
                    '<script defer defer src="search.js">',
                ),
                encoding="utf-8",
            )
            result = self.validate(root)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("only defer and src attributes", result.stderr)


if __name__ == "__main__":
    unittest.main()
