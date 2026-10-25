"""Download and publication regressions; these do not claim native/browser success."""
from __future__ import annotations

import hashlib
import os
import json
from pathlib import Path
import sys
import tempfile
import textwrap
import unittest
import time
import subprocess
import signal
from unittest.mock import patch
from urllib.parse import urlsplit
import zipfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from showcase_build.integration import (copy_composed_publication, install_output,
                                        pin_documentation_links, publish_examples)
from showcase_build.manifest import roots
from showcase_build.navigation import mount
from showcase_build.packaging import copy_sources, source_archive
from showcase_contract.site import ContractError, HtmlDocument
from report_views.reports import UtilityRegion, native_check_view, quality_view
from report_views.pages import Sections, publish as publish_report_pages


class BuildIntegrationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def write(self, relative: str, value: str | dict) -> Path:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        # Pin the newline so the bytes under test are identical on every
        # platform; Windows text mode would otherwise turn "\n" into "\r\n".
        path.write_text(json.dumps(value) if isinstance(value, dict) else value,
                        encoding="utf-8", newline="\n")
        return path

    def test_self_hosted_manual_links_follow_the_fork_revision_without_rewriting_ir(self) -> None:
        source = "https://github.com/lIlIIlIll/cjdoc/blob/main/"
        source_tree = "https://github.com/lIlIIlIll/cjdoc/tree/main/"
        repository = "https://github.com/example-owner/cjdoc-fork"
        revision = "c" * 40
        target = repository + "/blob/" + revision + "/"
        target_tree = repository + "/tree/" + revision + "/"
        foreign = "https://github.com/example-owner/another-project/blob/main/README.md"
        html_page = self.write("site/api/concepts/index.html",
            f'<a href="{source}docs/usage.md#generate">Usage</a>'
            f'<a href="{source}README.md">README</a><a href="{foreign}">Other</a>'
            f'<a href="{source_tree}docs/maintainer#build">Maintainer</a>'
            f'<code>{source}docs/usage.md</code>')
        original_markdown = (f'[Usage]({source}docs/usage.md#generate)\n'
                             f'[Maintainer]({source_tree}docs/maintainer#build)\n[Other]({foreign})\n')
        markdown = [self.write(path, original_markdown)
                    for path in ("site/markdown/concepts/index.md", "site/docs/README.md",
                                 "site/docs/i18n.md", "site/docs/documentation-quality.md")]
        author_ir = self.write("site/artifacts/docs.json", {"pages": [{"url": source + "docs/usage.md"}]})
        original_ir = author_ir.read_bytes()
        pin_documentation_links(self.root / "site", {"repository": repository, "revision": revision},
                                own_api_index=True)
        published = html_page.read_text(encoding="utf-8")
        self.assertIn(f'href="{target}docs/usage.md#generate"', published)
        self.assertIn(f'href="{target}README.md"', published)
        self.assertIn(f'href="{target_tree}docs/maintainer#build"', published)
        self.assertIn(f'href="{foreign}"', published)
        self.assertIn(f'<code>{source}docs/usage.md</code>', published)
        for path in markdown:
            self.assertEqual(path.read_text(encoding="utf-8"),
                             f'[Usage]({target}docs/usage.md#generate)\n'
                             f'[Maintainer]({target_tree}docs/maintainer#build)\n[Other]({foreign})\n')
        self.assertEqual(author_ir.read_bytes(), original_ir)

    def test_alternate_project_keeps_its_index_but_pins_copied_cjdoc_manuals(self) -> None:
        source = "https://github.com/lIlIIlIll/cjdoc"
        repository = "https://github.com/example-owner/cjdoc-fork"
        revision = "d" * 40
        html_index = self.write("site/api/concepts/index.html",
                               f'<a href="{source}/blob/main/README.md">Upstream cjdoc</a>')
        markdown_index = self.write("site/markdown/concepts/index.md",
                                   f'[Upstream cjdoc]({source}/blob/main/README.md)')
        original_indexes = [(path, path.read_bytes()) for path in (html_index, markdown_index)]
        manual = self.write("site/docs/README.md", f'[Usage]({source}/blob/main/docs/usage.md)')
        directory = self.write("site/docs/i18n.md", f'[Maintainer]({source}/tree/main/docs/maintainer)')
        readme = self.write("site/README.md", f'[Guide]({source}/blob/main/docs/guides.md)')
        pin_documentation_links(self.root / "site", {"repository": repository, "revision": revision},
                                own_api_index=False)
        self.assertEqual(manual.read_text(encoding="utf-8"),
                         f'[Usage]({repository}/blob/{revision}/docs/usage.md)')
        self.assertEqual(directory.read_text(encoding="utf-8"),
                         f'[Maintainer]({repository}/tree/{revision}/docs/maintainer)')
        self.assertEqual(readme.read_text(encoding="utf-8"),
                         f'[Guide]({repository}/blob/{revision}/docs/guides.md)')
        for path, original in original_indexes:
            self.assertEqual(path.read_bytes(), original)

    def test_source_download_preserves_paths_license_and_exact_configuration(self) -> None:
        inventory = ["examples/pocketkit/LICENSE", "examples/pocketkit/demo-v1/cjdoc.toml"]
        self.addCleanup(patch.stopall)
        patch("showcase_build.packaging.source_inputs", return_value=inventory).start()
        self.write("source/examples/pocketkit/LICENSE", "MIT license")
        configuration = '[external-docs.dep]\nversion="fixed-v1"\n[i18n]\ndefault-language="en"\n'
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

    def test_composed_publication_keeps_native_routes_and_only_public_machine_ir(self) -> None:
        self.write("composed/versions.json", {"versions": []})
        self.write("composed/demo-v1/index.html", '<a href="html/en/index.html">en</a>')
        self.write("composed/demo-v1/docs.json", {"authorOnly": "hidden documentation"})
        self.write("composed/demo-v1/markdown/private.md", "hidden documentation")
        self.write("composed/demo-v1/site-manifest.json", {"routes": []})
        self.write("composed/demo-v1/html/en/index.html", "public page")
        self.write("composed/demo-v1/html/en/machine/docs.json", {"public": True})
        self.write("composed/demo-v2/api-diff.json", {"changes": []})
        self.write("composed/demo-v1/doctest/results.json", {"results": []})
        copy_composed_publication(self.root / "composed", self.root / "published")
        self.assertTrue((self.root / "published/demo-v1/index.html").is_file())
        self.assertTrue((self.root / "published/demo-v2/api-diff.json").is_file())
        self.assertFalse((self.root / "published/demo-v1/doctest").exists())
        self.assertEqual(json.loads((self.root / "published/demo-v1/html/en/machine/docs.json").read_text()),
                         {"public": True})
        self.assertFalse((self.root / "published/demo-v1/docs.json").exists())
        self.assertFalse((self.root / "published/demo-v1/markdown").exists())
        self.assertFalse((self.root / "published/demo-v1/site-manifest.json").exists())
        self.assertTrue((self.root / "composed/demo-v1/docs.json").is_file())

    def test_source_copy_rejects_symlink_ancestor_before_copying_bytes(self) -> None:
        self.write("private/src/api.cj", "private contents")
        (self.root / "repo/examples").mkdir(parents=True)
        (self.root / "repo/examples/pocketkit").symlink_to(self.root / "private", target_is_directory=True)
        with patch("showcase_build.packaging.source_inputs", return_value=["examples/pocketkit/src/api.cj"]):
            with self.assertRaisesRegex(ContractError, "symlink"):
                copy_sources(self.root / "repo", self.root / "download")
        self.assertFalse((self.root / "download").exists())

    def test_bilingual_showcase_publishes_the_native_composition_once(self) -> None:
        composed = self.root / "composed"
        records, locales = [], {}
        for version in ("demo-v1", "demo-v2"):
            languages = []
            for locale in ("en", "zh-CN"):
                relative = f"{version}/html/{locale}"
                self.write(f"composed/{relative}/index.html", f"{version}/{locale}")
                languages.append({"language": locale, "root": relative})
            records.append({"id": version, "basePath": version, "languages": languages})
        self.write("composed/versions.json", {"schemaVersion": "cjdoc.versions/2", "versions": records})
        for locale in ("en", "zh-CN"):
            self.write(f"diagnostics/{locale}/html/index.html", "diagnostics")
            locales[locale] = {"composed": composed, "roots": {
                record["id"]: composed / record["languages"][0 if locale == "en" else 1]["root"]
                for record in records}, "diff": self.root / "diff.json",
                "diagnostics": self.root / "diagnostics" / locale}
        site = self.root / "site"
        with patch("showcase_build.integration.publish_reports") as reports:
            publish_examples({"locales": locales}, site, {"revision": "a" * 40})
        self.assertEqual(reports.call_count, 6)
        self.assertEqual(len(list((site / "examples").rglob("index.html"))), 4)
        for locale in ("en", "zh-CN"):
            self.assertFalse((site / "examples" / locale).exists())
            self.assertEqual(roots(site, locale)["demo-v2"], site / "examples/demo-v2/html" / locale)

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

    def test_legacy_output_marker_is_rejected_without_changing_either_tree(self) -> None:
        marker = self.write("output/build.json", {"schemaVersion": "cjdoc.showcase/1"})
        original = marker.read_bytes()
        self.write("output/index.html", "old")
        self.write("work/site/index.html", "new")
        with self.assertRaisesRegex(ContractError, "unowned output directory"):
            install_output(self.root / "work/site", self.root / "output")
        self.assertEqual(marker.read_bytes(), original)
        self.assertEqual((self.root / "output/index.html").read_text(), "old")
        self.assertEqual((self.root / "work/site/index.html").read_text(), "new")
        self.assertFalse((self.root / "work/previous-output").exists())

    def test_language_switch_uses_native_identity_when_paths_differ(self) -> None:
        for locale, path in (("zh-CN", "symbols/chinese.html"), ("en", "symbols/different-english.html")):
            self.write(f"site/{locale}/navigation-index.json", {"schemaVersion": "cjdoc.navigation-index/1", "pages": [
                {"id": "native-page", "symbolId": "same-native-symbol", "href": path}]})
            self.write(f"site/{locale}/{path}", '<html><head></head><body><h1 id="native-member">API</h1></body></html>')
        mount(self.root / "site/zh-CN", self.root / "site", "zh-CN", self.root / "site/en")
        page = (self.root / "site/zh-CN/symbols/chinese.html").read_text()
        self.assertIn('../../en/symbols/different-english.html', page)
        self.assertIn('data-locale-anchors="[&quot;native-member&quot;]"', page)

    def test_raw_markdown_follows_manifest_without_legacy_heading_or_page_fallback(self) -> None:
        root = self.root / "site/view"
        pages = [
            ("native-symbol", "symbols/entry.html", "agent/symbols/content-key.md", "Complete native declaration"),
            ("native-concept", "concepts/overview.html", "agent/pages/content-key.md", "Complete authored concept"),
            ("unrepresented-report", "report.html", None, None),
        ]
        self.write("site/view/navigation-index.json", {"schemaVersion": "cjdoc.navigation-index/1",
            "pages": [{"id": identity, "href": page} for identity, page, _, _ in pages]})
        self.write("site/view/agent/manifest.json", {"representations": [
            {"id": identity, "html": page, "markdown": markdown}
            for identity, page, markdown, _ in pages if markdown is not None]})
        # Legacy aggregate headings are not unique declaration or page identities.
        legacy = '<a id="same"></a>\n# `fixture.Entry`\n\n```cangjie\npublic class Entry\n```\n'
        self.write("site/view/machine/markdown/one.md", legacy)
        self.write("site/view/machine/markdown/two.md", legacy)
        self.write("site/view/machine/markdown/index.md", "Unrelated aggregate content")
        for _, page, markdown, content in pages:
            self.write("site/view/" + page, "<html><head></head><body>Native page</body></html>")
            if markdown is not None:
                self.write("site/view/" + markdown, content)
        mount(root, self.root / "site", "en")
        for _, page, _, expected in pages:
            origin = root / page
            links = HtmlDocument(origin.read_text(encoding="utf-8")).links
            consumed = [(origin.parent / urlsplit(link).path).resolve().read_text(encoding="utf-8")
                        for link in links if urlsplit(link).path.endswith(".md")]
            self.assertEqual(consumed, [] if expected is None else [expected])

    def test_native_check_evidence_rejects_modified_source(self) -> None:
        self.write("view/check-modes/src/api.cj", "modified")
        self.write("view/check-modes/native-check.json", {"schemaVersion": "cjdoc.showcase-native-check/1", "exitCode": 0,
            "command": ["cjdoc", "check", "--check-examples"],
            "scope": "aggregate command evidence; no per-example result claim", "sources": [
            {"path": "src/api.cj", "sha256": hashlib.sha256(b"original").hexdigest()}]})
        with self.assertRaisesRegex(ContractError, "source hash mismatch"):
            native_check_view(self.root / "view")

    def test_native_check_report_requires_successful_explicit_command_evidence(self) -> None:
        with self.assertRaisesRegex(ContractError, "evidence is required"):
            native_check_view(self.root / "view")
        source = self.write("view/check-modes/src/api.cj", "package checks\n")
        evidence = {"schemaVersion": "cjdoc.showcase-native-check/1", "exitCode": 0,
                    "command": ["cjdoc", "check", "--check-examples"],
                    "scope": "aggregate command evidence; no per-example result claim",
                    "sources": [{"path": "src/api.cj", "sha256": hashlib.sha256(source.read_bytes()).hexdigest()}]}
        for key, value in (("schemaVersion", "unsupported"), ("scope", "per-example results"),
                           ("exitCode", 1), ("command", ["cjdoc", "check"])):
            with self.subTest(key=key):
                self.write("view/check-modes/native-check.json", {**evidence, key: value})
                with self.assertRaises(ContractError):
                    native_check_view(self.root / "view")
        self.write("view/check-modes/native-check.json", evidence)
        rendered = native_check_view(self.root / "view")
        self.assertIn('id="native-check"', rendered)
        self.assertIn("no per-example result claim", rendered)
        self.assertNotIn("data-doctest-status", rendered)

    def test_focused_reports_use_native_check_route_and_keep_diagnostic_evidence_separate(self) -> None:
        sections = "".join(f'<section id="{name}"><p>{name}</p></section>'
                           for name in ("native-check", "api-diff", "coverage", "quality", "diagnostics", "provenance"))
        self.write("view/validation.html", '<html><head><title>Validation</title></head><body>'
                   '<div class="validation-page"><h1>Validation</h1>' + sections + '</div></body></html>')
        self.write("view/report-provenance.json", {"locale": "en"})
        publish_report_pages(self.root / "view")
        self.assertIn('<section id="native-check">', (self.root / "view/report-native-check.html").read_text())
        self.assertFalse((self.root / "view/report-doctest.html").exists())
        diagnostics = (self.root / "view/report-diagnostics.html").read_text()
        self.assertIn('<section id="diagnostics">', diagnostics)
        self.assertNotIn('<section id="native-check">', diagnostics)

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



class CoordinatorSignalCleanupTests(unittest.TestCase):
    """A cancelled coordinator must not leave an isolated group running.

    Run in a real subprocess: the handler deliberately re-raises the signal once the
    groups are gone, so delivering it in-process would kill the test runner.
    """

    @unittest.skipUnless(os.name == "posix", "POSIX process groups only")
    def test_a_signal_stops_further_launches(self) -> None:
        """No new detached session may start after the handler has run."""
        from showcase_build import parallel

        # Inherit SIG_IGN so the handler returns instead of re-raising into the
        # test runner; the cancellation flag is what this asserts.
        previous = signal.signal(signal.SIGTERM, signal.SIG_IGN)
        try:
            runner = parallel.BranchRunner()
            runner._on_signal(signal.SIGTERM, None)
            self.assertTrue(runner.cancelled)
            with self.assertRaises(parallel.CancelledError):
                runner.run(["/bin/true"])
        finally:
            signal.signal(signal.SIGTERM, previous)

    @unittest.skipUnless(os.name == "posix", "POSIX process groups only")
    def test_a_signal_while_the_lock_is_held_does_not_deadlock(self) -> None:
        """The handler runs on the interrupted thread, which may already hold the lock."""
        helper = textwrap.dedent(
            """
            import signal, subprocess, sys, time
            sys.path.insert(0, sys.argv[1])
            from showcase_build.parallel import BranchRunner
            runner = BranchRunner()
            child = subprocess.Popen(["/bin/bash", "-c", "exec -a marker-%d sleep 30" % __import__("os").getpid()],
                                     start_new_session=True)
            with runner._lock:
                runner._processes.add(child)
                print("held", flush=True)
                # The signal arrives while this thread owns the lock.
                time.sleep(30)
            """)
        coordinator = subprocess.Popen(
            [sys.executable, "-c", helper, str(ROOT / "scripts")],
            stdout=subprocess.PIPE, text=True)
        try:
            self.assertEqual(coordinator.stdout.readline().strip(), "held")
            coordinator.send_signal(signal.SIGTERM)
            coordinator.wait(timeout=10)
            self.assertIsNotNone(coordinator.returncode,
                                 "the coordinator deadlocked instead of cancelling")
        finally:
            if coordinator.poll() is None:
                coordinator.kill()
                coordinator.wait(timeout=10)

    @unittest.skipUnless(os.name == "posix", "POSIX process groups only")
    def test_an_ignored_signal_is_not_turned_into_a_fatal_one(self) -> None:
        """An inherited SIG_IGN must survive: the coordinator keeps running."""
        helper = textwrap.dedent(
            """
            import signal, sys, time
            sys.path.insert(0, sys.argv[1])
            from showcase_build.parallel import BranchRunner
            signal.signal(signal.SIGINT, signal.SIG_IGN)
            runner = BranchRunner()
            print("ready", flush=True)
            time.sleep(30)
            """)
        coordinator = subprocess.Popen(
            [sys.executable, "-c", helper, str(ROOT / "scripts")],
            stdout=subprocess.PIPE, text=True)
        try:
            self.assertEqual(coordinator.stdout.readline().strip(), "ready")
            coordinator.send_signal(signal.SIGINT)
            # It must still be there: resetting the disposition would have killed it.
            with self.assertRaises(subprocess.TimeoutExpired):
                coordinator.wait(timeout=2)
        finally:
            coordinator.kill()
            coordinator.wait(timeout=10)

    @unittest.skipUnless(os.name == "posix", "POSIX process groups only")
    def test_sigterm_kills_a_registered_group_before_exiting(self) -> None:
        helper = textwrap.dedent(
            """
            import os, subprocess, sys, time
            sys.path.insert(0, sys.argv[1])
            from showcase_build.parallel import BranchRunner
            runner = BranchRunner()
            marker = sys.argv[2]
            child = subprocess.Popen(["/bin/bash", "-c", f"exec -a {marker} sleep 30"],
                                     start_new_session=True)
            with runner._lock:
                runner._processes.add(child)
            print("ready", flush=True)
            time.sleep(30)
            """)
        marker = f"cjdoc-signal-cleanup-{os.getpid()}"
        coordinator = subprocess.Popen(
            [sys.executable, "-c", helper, str(ROOT / "scripts"), marker],
            stdout=subprocess.PIPE, text=True)
        try:
            self.assertEqual(coordinator.stdout.readline().strip(), "ready")
            coordinator.send_signal(signal.SIGTERM)
            self.assertIsNotNone(coordinator.wait(timeout=10),
                                 "the coordinator ignored SIGTERM")
            # The detached child shares the runner's group registration, so if the
            # handler did not kill it, it is still alive now.
            deadline = time.monotonic() + 5
            alive = True
            while time.monotonic() < deadline:
                probe = subprocess.run(["pgrep", "-f", marker],
                                       capture_output=True, text=True)
                alive = bool(probe.stdout.strip())
                if not alive:
                    break
                time.sleep(0.1)
            self.assertFalse(alive, "the registered group survived the coordinator")
        finally:
            if coordinator.poll() is None:
                coordinator.kill()
                coordinator.wait(timeout=10)
            subprocess.run(["pkill", "-f", marker], check=False)
