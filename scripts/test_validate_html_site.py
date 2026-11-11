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
    "default-src 'none'; script-src 'self' file:; style-src 'self' file:; img-src 'self' file:; "
    "base-uri 'none'; form-action 'none'"
)


def _decode_script_text(source: str) -> str:
    escapes = {"n": "\n", "r": "\r", "t": "\t", "f": "\f", "v": "\v",
               "b": "\b", "0": "\0", "\\": "\\", '"': '"', "'": "'", "$": "$"}
    result = []
    index = 0
    while index < len(source):
        value = source[index]
        index += 1
        if value != "\\":
            result.append(value)
            continue
        escape = source[index]
        index += 1
        if escape == "u" and source[index] == "{":
            end = source.index("}", index)
            result.append(chr(int(source[index + 1:end], 16)))
            index = end + 1
        else:
            result.append(escapes[escape])
    return "".join(result)


def _script_literal(path: Path, name: str, prefix: str = "") -> str:
    """Reproduce a static Cangjie literal, including its emitted newlines."""
    source = path.read_text(encoding="utf-8")
    raw_marker = f'internal let {name} = {prefix}#"\n'
    if raw_marker in source:
        return "\n" + source.split(raw_marker, 1)[1].split('\n"#', 1)[0] + "\n"
    marker = f'internal let {name} = {prefix}"""\n'
    return _decode_script_text(source.split(marker, 1)[1].split('\n"""', 1)[0]) + "\n"


def canonical_search_script() -> str:
    """search.js bytes, in the order renderers_output.cj concatenates them."""
    render = SCRIPT.parent.parent / "src/render"
    return (_script_literal(render / "html_sidebar_script.cj", "HTML_SIDEBAR_SCRIPT")
            + _script_literal(render / "html_search_kernel.cj", "HTML_SEARCH_KERNEL_SCRIPT")
            + _script_literal(render / "html_scripts.cj", "HTML_SEARCH_CONTROLLER_SCRIPT")
            + _script_literal(render / "html_script_reading.cj", "HTML_READING_SCRIPT")
            + _script_literal(render / "html_script_language.cj", "LANGUAGE_NAVIGATION_SCRIPT"))


def canonical_theme_bootstrap_script() -> str:
    return _script_literal(SCRIPT.parent.parent / "src/render/html_scripts.cj",
                           "HTML_THEME_BOOTSTRAP_SCRIPT")


def canonical_symbol_alias_script() -> str:
    return _script_literal(SCRIPT.parent.parent / "src/render/html_routing.cj",
                           "HTML_SYMBOL_ALIAS_SCRIPT")


class ValidateHtmlSiteTest(unittest.TestCase):
    def write_site(self, root: Path) -> None:
        index = (
            "<!doctype html><html><head>"
            f'<meta http-equiv="Content-Security-Policy" content="{CSP}">'
            "</head><body data-cjdoc-route=\"overview\" data-cjdoc-page=\"home\">"
            '<main id="top"><a href="#top">top</a></main>'
            '<dialog id="cjdoc-search-dialog"><input id="cjdoc-search-input">'
            '<div id="cjdoc-search-filters"></div><ul id="cjdoc-search-results"></ul></dialog>'
            '<dialog id="cjdoc-theme-popover"><h2 id="cjdoc-settings-title">Display</h2></dialog>'
            '<script src="theme-bootstrap.js"></script>'
            '<script defer src="search-index.js"></script>'
            '<script defer src="sidebar-index.js"></script>'
            '<script defer src="search.js"></script></body></html>'
        )
        (root / "index.html").write_text(index, encoding="utf-8", newline="\n")
        (root / "theme-bootstrap.js").write_text(
            canonical_theme_bootstrap_script(), encoding="utf-8", newline="\n"
        )
        (root / "search.js").write_text(
            canonical_search_script(), encoding="utf-8", newline="\n"
        )
        (root / "symbol-alias.js").write_text(
            canonical_symbol_alias_script(), encoding="utf-8", newline="\n"
        )
        canonical_id = "cjdoc:v2:fixture:example"
        entry = {
            "id": canonical_id,
            "canonicalId": canonical_id,
            "snapshotId": "fixture-snapshot",
            "scope": 0,
            "concept": False,
            "genericArity": 0,
            "ownerId": None,
            "name": "example",
            "qualifiedName": "Fixture.example",
            "kind": "function",
            "packageName": "Fixture",
            "ownerName": None,
            "ownerQualifiedName": None,
            "symbolKey": None,
            "parameterTypes": ["String"],
            "returnType": "Unit",
            "returnCanonical": "std.core.Unit",
            "summary": "A fixture summary.",
            "summaryDisplay": "A fixture summary.",
            "body": "A fixture summary.",
            "bodyTruncated": False,
            "href": "index.html#top",
            "exposures": [],
            "sections": [],
            "externalDocs": [],
            "bindings": [],
            "classification": {"group": None, "tags": []},
        }
        search_text = json.dumps(
            {
                "schemaVersion": "cjdoc.search-index/11",
                "profile": "bounded-static",
                "contract": {"version": "cjdoc.search-contract/2"},
                "projectionId": "fixture-projection",
                "scope": {
                    "snapshotId": "fixture-snapshot",
                    "sourceSnapshotId": "fixture-source-snapshot",
                    "publicationRevision": "",
                    "project": "Fixture",
                    "language": "en",
                    "audience": "external",
                    "cfgProfile": "",
                    "apiCollectionState": "resolved",
                },
                "coverage": {
                    "profile": "bounded-static",
                    "projectionId": "fixture-projection",
                    "bodyTextLimit": 2000,
                    "bodyComplete": True,
                    "truncatedEntries": 0,
                },
                "modules": [{
                    "moduleId": "fixture-module",
                    "moduleName": "Fixture",
                    "documentSet": None,
                    "dependency": None,
                    "dependencyInstanceState": "not_applicable",
                }],
                "tags": [],
                "entries": [entry],
            },
            separators=(",", ":"),
        )
        (root / "search-index.json").write_text(
            search_text + "\n", encoding="utf-8", newline="\n"
        )
        signature_text = json.dumps({canonical_id: "func example(String)"}, separators=(",", ":"))
        (root / "search-index.js").write_text(
            "globalThis.__CJDOC_SEARCH_INDEX__ = " + search_text
            + ";\nglobalThis.__CJDOC_SEARCH_SIGNATURES__ = " + signature_text + ";\n",
            encoding="utf-8", newline="\n",
        )
        sidebar = {
            "version": 2,
            "packages": [{
                "id": "index.html", "label": "Fixture", "href": "index.html",
                "types": [canonical_id],
            }],
            "types": {canonical_id: {
                "label": "example", "kind": "function", "kindLabel": "function",
                "href": "index.html", "members": [canonical_id + ":member"],
            }},
            "members": {canonical_id + ":member": {
                "label": "example()", "kind": "function", "kindLabel": "function",
                "anchor": "top",
            }},
        }
        (root / "sidebar-index.js").write_text(
            "globalThis.__CJDOC_SIDEBAR_INDEX__=" + json.dumps(sidebar) + ";\n",
            encoding="utf-8", newline="\n",
        )

    def validate(self, root: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPT), str(root)],
            check=False,
            capture_output=True,
            text=True,
        )

    def rewrite_search(self, root: Path, search: dict) -> None:
        search_text = json.dumps(search, separators=(",", ":"))
        (root / "search-index.json").write_text(
            search_text + "\n", encoding="utf-8", newline="\n"
        )
        signatures = {
            entry["canonicalId"]: "func example(String)" for entry in search["entries"]
        }
        signature_text = json.dumps(signatures, separators=(",", ":"))
        (root / "search-index.js").write_text(
            "globalThis.__CJDOC_SEARCH_INDEX__ = " + search_text
            + ";\nglobalThis.__CJDOC_SEARCH_SIGNATURES__ = " + signature_text + ";\n",
            encoding="utf-8", newline="\n",
        )


    def test_accepts_well_formed_external_script_site(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_site(root)
            result = self.validate(root)
            self.assertEqual(result.returncode, 0, result.stderr)


    def test_accepts_classification_with_nullable_group_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_site(root)
            search = json.loads((root / "search-index.json").read_text(encoding="utf-8"))
            search["tags"] = [{"scope": 0, "id": "stream", "title": "Streaming"}]
            search["entries"][0]["classification"] = {
                "group": {
                    "id": "api", "packageName": "Fixture", "ownerId": None,
                    "title": "API", "order": None,
                },
                "tags": [{"id": "stream", "title": "Streaming"}],
            }
            self.rewrite_search(root, search)
            result = self.validate(root)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_unknown_classification_fields(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_site(root)
            search = json.loads((root / "search-index.json").read_text(encoding="utf-8"))
            search["entries"][0]["classification"]["extra"] = None
            self.rewrite_search(root, search)
            result = self.validate(root)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("classification has an invalid shape", result.stderr)

    def test_rejects_classification_titles_over_utf8_byte_limit(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_site(root)
            search = json.loads((root / "search-index.json").read_text(encoding="utf-8"))
            title = "é" * 129
            search["tags"] = [{"scope": 0, "id": "stream", "title": title}]
            search["entries"][0]["classification"]["tags"] = [
                {"id": "stream", "title": title}
            ]
            self.rewrite_search(root, search)
            result = self.validate(root)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("search tag identity or title is invalid", result.stderr)

    def test_alias_requires_canonical_script_and_valid_target(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_site(root)
            alias = root / "api.html"
            alias.write_text(
                f'<!doctype html><html><head><meta http-equiv="Content-Security-Policy" content="{CSP}">'
                '</head><body data-cjdoc-route="symbol-alias"><a data-cjdoc-alias-target href="index.html">API</a>'
                '<script src="symbol-alias.js" defer></script></body></html>', encoding="utf-8")
            self.assertEqual(self.validate(root).returncode, 0)
            alias.write_text(alias.read_text(encoding="utf-8").replace('href="index.html"', 'href="missing.html"'), encoding="utf-8")
            self.assertIn("broken local link", self.validate(root).stderr)
            (root / "symbol-alias.js").write_text("location.replace('https://evil.test')", encoding="utf-8")
            alias.unlink()
            self.assertIn("symbol-alias.js differs", self.validate(root).stderr)

    def test_rejects_missing_structured_search_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_site(root)
            search = json.loads((root / "search-index.json").read_text(encoding="utf-8"))
            entry = search["entries"][0]
            del entry["parameterTypes"]
            search_text = json.dumps(search, separators=(",", ":"))
            (root / "search-index.json").write_text(search_text + "\n", encoding="utf-8")
            signatures = json.dumps({entry["canonicalId"]: "func example(String)"}, separators=(",", ":"))
            (root / "search-index.js").write_text(
                "globalThis.__CJDOC_SEARCH_INDEX__ = " + search_text
                + ";\nglobalThis.__CJDOC_SEARCH_SIGNATURES__ = " + signatures + ";\n",
                encoding="utf-8",
            )
            result = self.validate(root)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("invalid search entry fields", result.stderr)


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
                page.replace(meta, "").replace("<body", meta + "<body", 1),
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
            marker = "\"entries\":["
            self.assertIn(marker, script)
            (root / "search-index.js").write_text(
                script.replace(marker, "\"entries\":[{\"extra\":true},", 1),
                encoding="utf-8",
            )
            result = self.validate(root)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("payload differs", result.stderr)

    def test_rejects_executable_sidebar_payload_and_escaped_targets(self) -> None:
        for mutation in ("statement", "escaped-target", "unknown-member", "prototype",
                        "broken-anchor"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self.write_site(root)
                source = root / "sidebar-index.js"
                prefix = "globalThis.__CJDOC_SIDEBAR_INDEX__="
                text = source.read_text(encoding="utf-8")
                payload = json.loads(text[len(prefix):-2])
                if mutation == "statement":
                    text = text[:-2] + ";globalThis.injected=true;\n"
                else:
                    if mutation == "escaped-target":
                        payload["types"]["cjdoc:v2:fixture:example"]["href"] = "../outside.html"
                    elif mutation == "unknown-member":
                        payload["types"]["cjdoc:v2:fixture:example"]["members"] = ["missing"]
                    elif mutation == "prototype":
                        payload["types"]["__proto__"] = payload["types"].pop(
                            "cjdoc:v2:fixture:example")
                    else:
                        payload["members"]["cjdoc:v2:fixture:example:member"]["anchor"] = "missing"
                    text = prefix + json.dumps(payload) + ";\n"
                source.write_text(text, encoding="utf-8")
                result = self.validate(root)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("sidebar-index.js", result.stderr)

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
