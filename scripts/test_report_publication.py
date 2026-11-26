"""Exercise Agent discovery and report attachments through the native CLI."""
from __future__ import annotations

import hashlib
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from urllib.parse import unquote, urlsplit

REPO = Path(__file__).resolve().parent.parent
PROJECT = "publication_probe"


class ReportSlots(HTMLParser):
    def __init__(self, page: Path):
        super().__init__()
        self.current = None
        self.slots = {}
        self.feed(page.read_text(encoding="utf-8"))

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "p" and "data-cjdoc-report-kind" in attrs:
            self.current = attrs["data-cjdoc-report-kind"]
            if self.current in self.slots:
                raise AssertionError(f"duplicate attachment slot: {self.current}")
            self.slots[self.current] = (attrs["data-cjdoc-report-state"], [])
        elif tag == "a" and self.current:
            self.slots[self.current][1].append(attrs["href"])

    def handle_endtag(self, tag):
        if tag == "p":
            self.current = None


def write_project(root: Path, symbol: str) -> None:
    (root / "src").mkdir(parents=True)
    (root / "cjpm.toml").write_text(
        f'[package]\nname = "{PROJECT}"\ncjc-version = "1.2.0"\n'
        'version = "1.0.0"\noutput-type = "static"\n', encoding="utf-8")
    (root / "src" / "api.cj").write_text(
        f"package {PROJECT}\npublic func {symbol}(): Int64 {{ 1 }}\n", encoding="utf-8")
    (root / "docs").mkdir()
    config = '[i18n]\ndefault-language = "en"\nlanguages = ["en", "zh-CN"]\n'
    for kind, slug in (("project", "overview"), ("module", "module"), ("package", "package"),
                       ("guide", "first-guide"), ("guide", "second-guide")):
        (root / "docs" / f"{slug}.md").write_text(f"# {slug}\n\nPublic documentation.\n",
                                                encoding="utf-8")
        config += (f'\n[[docs.pages]]\nsource = "docs/{slug}.md"\n'
                   f'route = "concepts/catalog/{slug}"\nkind = "{kind}"\n')
    (root / "cjdoc.toml").write_text(config, encoding="utf-8")


class ReportPublicationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        binary = Path(os.environ.get("CJDOC_BINARY", REPO / "target/release/bin/main"))
        windows = binary.with_suffix(".exe")
        cls.binary = (windows if os.name == "nt" and windows.is_file() else binary).resolve(strict=True)

    def cli(self, *args):
        result = subprocess.run([str(self.binary), *map(str, args)], capture_output=True, timeout=300)
        self.assertEqual(result.returncode, 0, result.stderr.decode("utf-8", errors="replace"))
        return result.stdout

    def generation(self, source):
        return ("generate", "--project", source, "--semantic", "source", "--no-cache", "--lint-profile", "off")

    def site(self, command, output, language, reports=()):
        self.cli(*command, "--format", "html", "--output", output,
                 "--doc-version", "1.0.0", *language, *reports)
        return output / "html"

    def report_states(self, page, expected):
        slots = ReportSlots(page).slots
        self.assertEqual(set(slots), {"validation", "api-diff"})
        for kind, (state, links) in slots.items():
            if kind not in expected:
                self.assertEqual((state, links), ("absent", []))
                continue
            self.assertEqual(state, "attached")
            href, = links
            self.assertEqual(urlsplit(href).scheme, "")
            self.assertEqual((page.parent / unquote(href)).resolve(strict=True), expected[kind].resolve(strict=True))
        self.assertRegex(page.read_text(encoding="utf-8"), r"not a passing check or a compatibility verdict|不代表检查通过或兼容性结论")

    def check_site(self, html, roots, reports):
        for relative in roots:
            root = html / relative
            manifest = json.loads((root / "agent" / "manifest.json").read_bytes())
            entries = {entry["kind"]: entry for entry in manifest["reports"]}
            self.assertEqual(set(entries), set(reports))
            paths = {}
            for kind, original in reports.items():
                entry = entries[kind]
                published = root / entry["path"]
                self.assertEqual(published.read_bytes(), original.read_bytes())
                self.assertEqual(entry["sha256"], hashlib.sha256(original.read_bytes()).hexdigest())
                paths[kind] = published
            self.report_states(root / "validation.html", paths)

    def test_generate_render_and_compose_publish_report_evidence_in_every_locale(self):
        with tempfile.TemporaryDirectory(prefix="cjdoc-report-publication-") as temp:
            # Output publication rejects symbolic-link ancestors, and the macOS
            # temporary directory lives under the /var symlink.
            root = Path(temp).resolve()
            before, after = root / "before", root / "after"
            write_project(before, "removedValue")
            write_project(after, "newValue")
            snapshot = root / "after.json"
            snapshot.write_bytes(self.cli(*self.generation(after), "--format", "json", "--stdout"))
            replay = ("render", "--input", snapshot)
            for file, command in (("before", self.generation(before)), ("after", replay)):
                (root / f"{file}-surface.json").write_bytes(self.cli(*command, "--format", "api-surface", "--stdout"))
            diff = root / "diff.json"
            diff.write_bytes(self.cli("diff", "--baseline", root / "before-surface.json",
                                      "--current", root / "after-surface.json", "--format", "json"))
            comparison = json.loads(diff.read_bytes())
            self.assertEqual(comparison["schemaVersion"], "cjdoc.api-diff/2")
            self.assertTrue(comparison["entries"])
            validation = root / "coverage.json"
            validation.write_bytes(self.cli(*replay, "--format", "coverage", "--stdout"))
            self.assertEqual(json.loads(validation.read_bytes())["schemaVersion"], "cjdoc.documentation-coverage/2")
            both = ("--validation-report", validation, "--api-diff-report", diff)
            for name, languages, paths in (("single", ("--locale", "en"), ("",)),
                                           ("all", ("--all-languages",), ("en", "zh-CN"))):
                with self.subTest(languages=name):
                    for mode, command in (("generate", self.generation(after)), ("render", replay)):
                        attached = self.site(command, root / f"{name}-{mode}-attached", languages, both)
                        self.check_site(attached, paths, {"validation": validation, "api-diff": diff})
                        absent = self.site(command, root / f"{name}-{mode}-absent", languages)
                        self.check_site(absent, paths, {})
                    base = self.site(replay, root / f"{name}-base", languages, ("--validation-report", validation))
                    for use_diff in (False, True):
                        composed = root / f"{name}-composed-{use_diff}"
                        extra = ("--diff", f"1.0.0={diff}") if use_diff else ()
                        source = base.parent if name == "all" else base
                        self.cli("versions", "compose", "--version", f"1.0.0={source}", "--output", composed, *extra)
                        entry, = json.loads((composed / "versions.json").read_bytes())["versions"]
                        self.assertEqual(entry["apiDiff"] is not None, use_diff)
                        language_roots = {row["language"]: row["root"] for row in entry.get("languages", [])}
                        if name == "all":
                            self.assertEqual(set(language_roots), set(paths))
                        for relative in paths:
                            document = composed / (language_roots[relative] if relative else entry["basePath"])
                            expected = {"validation": document / "agent/reports/validation.json"}
                            self.assertEqual(expected["validation"].read_bytes(), validation.read_bytes())
                            if use_diff:
                                expected["api-diff"] = composed / entry["apiDiff"]
                                self.assertEqual(expected["api-diff"].read_bytes(), diff.read_bytes())
                            self.report_states(document / "validation.html", expected)

    def test_agent_directory_links_concept_kinds_to_the_navigation_index(self):
        with tempfile.TemporaryDirectory(prefix="cjdoc-agent-navigation-") as temp:
            root = Path(temp).resolve()
            project = root / "project"
            write_project(project, "value")
            site = self.site(self.generation(project), root / "site", ("--locale", "en"))
            llms = (site / "llms.txt").read_text(encoding="utf-8")
            nav = {page["href"]: page["kind"] for page in json.loads(
                (site / "navigation-index.json").read_bytes())["pages"]}
            for group, kind, slugs in (("Project overview", "project", ("overview",)),
                                       ("Modules", "module", ("module",)),
                                       ("Package overviews", "package", ("package",)),
                                       ("Guides", "guide", ("first-guide", "second-guide"))):
                self.assertIn(f"### {group}\n", llms)
                section = llms.split(f"### {group}\n", 1)[1].split("\n##", 1)[0]
                for slug in slugs:
                    path = f"concepts/catalog/{slug}.html"
                    self.assertIn(f"](<{path}>)", section)
                    self.assertTrue((site / path).is_file())
                    self.assertEqual(nav[path], kind)
            api = llms.split("## API packages\n", 1)[1]
            self.assertNotIn("](<concepts/", api)
            self.assertIn(f"](<packages/{PROJECT}/index.html>)", api)

    def test_cropped_agent_directory_preserves_other_groups_and_exact_navigation(self):
        with tempfile.TemporaryDirectory(prefix="cjdoc-cropped-navigation-") as temp:
            root = Path(temp).resolve()
            project = root / "project"
            write_project(project, "value")
            config = project / "cjdoc.toml"
            with config.open("a", encoding="utf-8", newline="\n") as f:
                for index in range(22):
                    slug = f"large-module-{index:02}"
                    title = f"Module {index} " + "full heading " * 710
                    (project / "docs" / f"{slug}.md").write_text(f"# {title}\n", encoding="utf-8")
                    f.write(f'\n[[docs.pages]]\nsource = "docs/{slug}.md"\n'
                            f'route = "concepts/catalog/{slug}"\nkind = "module"\n')
            site = self.site(self.generation(project), root / "site", ("--locale", "en"))
            llms = (site / "llms.txt").read_text(encoding="utf-8")
            self.assertIn("Additional conceptual pages are listed in navigation-index.json", llms)
            self.assertIn("[Navigation index](navigation-index.json)", llms)
            self.assertIn("](<concepts/catalog/second-guide.html>)", llms)
            self.assertIn(f"](<packages/{PROJECT}/index.html>)", llms)
            pages = json.loads((site / "navigation-index.json").read_bytes())["pages"]
            modules = {page["href"] for page in pages if "large-module-" in page["href"]}
            listed = {route for route in modules if f"](<{route}>)" in llms}
            self.assertEqual(len(modules), 22)
            self.assertTrue(set() < listed < modules)


if __name__ == "__main__":
    unittest.main()
