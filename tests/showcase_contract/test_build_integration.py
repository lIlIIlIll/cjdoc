"""Download and publication regressions; these do not claim native/browser success."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
from showcase_build.integration import install_output
from showcase_build.navigation import mount, markdown_declarations
from showcase_build.packaging import copy_sources, source_archive
from showcase_contract.site import ContractError
from report_views.reports import UtilityRegion, native_check_view, quality_view
from report_views.pages import Sections


class BuildIntegrationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def write(self, relative: str, value: str | dict) -> Path:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value) if isinstance(value, dict) else value, encoding="utf-8")
        return path

    def test_source_download_preserves_paths_license_and_exact_configuration(self) -> None:
        inventory = ["examples/pocketkit/LICENSE", "examples/pocketkit/demo-v1/cjdoc.toml"]
        self.addCleanup(patch.stopall)
        patch("showcase_build.packaging.source_inputs", return_value=inventory).start()
        self.write("source/examples/pocketkit/LICENSE", "MIT license")
        configuration = '[external-docs.dep]\nversion="fixed-v1"\n[doctest]\nmode="deny"\n'
        self.write("source/examples/pocketkit/demo-v1/cjdoc.toml", configuration)
        self.write("source/examples/pocketkit/demo-v1/target/stale.json", "stale")
        self.write("source/examples/pocketkit/.env", "secret must never be published")
        for version in ("demo-v1", "demo-v2"):
            self.write(f"source/examples/pocketkit/{version}/docs/support-symbol-index.json", '{}')
        site = self.root / "site"
        site.mkdir()
        result = source_archive(self.root / "source", site, {"repository": "https://github.com/o/r", "revision": "a" * 40})
        archive = site / result["path"]
        first = archive.read_bytes()
        with zipfile.ZipFile(archive) as download:
            self.assertEqual(download.read("examples/pocketkit/demo-v1/cjdoc.toml").decode(), configuration)
            self.assertNotIn("examples/pocketkit/demo-v1/target/stale.json", download.namelist())
            self.assertNotIn("examples/pocketkit/.env", download.namelist())
            metadata = json.loads(download.read("source.json"))
            self.assertEqual(metadata["revision"], "a" * 40)
            for name, digest in metadata["files"].items():
                self.assertEqual(hashlib.sha256(download.read(name)).hexdigest(), digest)
        source_archive(self.root / "source", site, {"repository": "https://github.com/o/r", "revision": "a" * 40})
        self.assertEqual(first, archive.read_bytes())

    def test_unowned_output_is_preserved(self) -> None:
        self.write("output/user.txt", "preserve")
        self.write("work/site/index.html", "new")
        with self.assertRaises(ContractError):
            install_output(self.root / "work/site", self.root / "output")
        self.assertEqual((self.root / "output/user.txt").read_text(), "preserve")

    def test_source_copy_rejects_symlink_ancestor_before_copying_bytes(self) -> None:
        self.write("private/src/api.cj", "private contents")
        (self.root / "repo/examples").mkdir(parents=True)
        (self.root / "repo/examples/pocketkit").symlink_to(self.root / "private", target_is_directory=True)
        with patch("showcase_build.packaging.source_inputs", return_value=["examples/pocketkit/src/api.cj"]):
            with self.assertRaisesRegex(ContractError, "symlink"):
                copy_sources(self.root / "repo", self.root / "download")
        self.assertFalse((self.root / "download").exists())

    def test_failed_replacement_restores_owned_output(self) -> None:
        self.write("output/build.json", {"schemaVersion": "cjdoc.showcase/2"})
        self.write("output/index.html", "old")
        self.write("work/site/index.html", "new")
        import os
        replace = os.replace

        def failing_replace(source, target):
            if Path(source) == self.root / "work/site":
                raise OSError("injected publication failure")
            replace(source, target)

        with patch("showcase_build.integration.os.replace", side_effect=failing_replace):
            with self.assertRaises(OSError):
                install_output(self.root / "work/site", self.root / "output")
        self.assertEqual((self.root / "output/index.html").read_text(), "old")

    def test_language_switch_uses_native_identity_when_paths_differ(self) -> None:
        for locale, path in (("zh-CN", "symbols/chinese.html"), ("en", "symbols/different-english.html")):
            self.write(f"site/{locale}/navigation-index.json", {"schemaVersion": "cjdoc.navigation-index/1", "pages": [
                {"id": "native-page", "symbolId": "same-native-symbol", "href": path}]})
            self.write(f"site/{locale}/{path}", '<html><head></head><body><h1 id="native-member">API</h1></body></html>')
        mount(self.root / "site/zh-CN", self.root / "site", "zh-CN", self.root / "site/en")
        page = (self.root / "site/zh-CN/symbols/chinese.html").read_text()
        self.assertIn('../../en/symbols/different-english.html', page)
        self.assertIn('data-locale-anchors="[&quot;native-member&quot;]"', page)

    def test_markdown_targets_use_emitted_anchors_in_arbitrary_native_paths(self) -> None:
        source = '<a id="native-anchor"></a>\n# `fixture.Type`\n\n```cangjie\npublic class Type\n```\n'
        markdown = self.write("view/machine/markdown/symbols/native-route.md", source)
        self.assertEqual(markdown_declarations(self.root / "view"), {("fixture.Type", "public class Type"): markdown})
        self.write("view/machine/markdown/ambiguous.md", source)
        with self.assertRaisesRegex(ContractError, "ambiguous native Markdown"):
            markdown_declarations(self.root / "view")

    def test_native_check_evidence_rejects_modified_source(self) -> None:
        self.write("view/check-modes/src/api.cj", "modified")
        self.write("view/check-modes/native-check.json", {"schemaVersion": "cjdoc.showcase-native-check/1", "exitCode": 0,
            "scope": "aggregate command evidence; no per-example result claim", "sources": [
            {"path": "src/api.cj", "sha256": hashlib.sha256(b"original").hexdigest()}]})
        with self.assertRaisesRegex(ContractError, "source hash mismatch"):
            native_check_view(self.root / "view")

    def test_quality_values_are_copied_and_heuristic_boundary_remains_visible(self) -> None:
        value = {"audience": "external", "assessment": "conservative-placeholder-heuristic",
                 "symbols": {"meaningful": 3, "total": 7, "percent": 42},
                 "parameters": {"meaningful": 1, "total": 3, "percent": 33}, "findings": []}
        rendered = quality_view(value, self.root, {})
        self.assertIn("conservative-placeholder-heuristic", rendered)
        self.assertIn("<td>42</td>", rendered)
        self.assertIn("<td>33</td>", rendered)

    def test_native_report_component_positions_do_not_shadow_htmlparser_offset(self) -> None:
        source = '<html>\n<div class="validation-page"><section id="coverage"><div>value</div></section></div></html>'
        start, end = UtilityRegion(source).regions[0]
        component = source[start:end]
        left, right = Sections(component).regions["coverage"]
        self.assertEqual(component[left:right], '<section id="coverage"><div>value</div></section>')


if __name__ == "__main__":
    unittest.main()
