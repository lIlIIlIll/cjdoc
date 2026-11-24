"""Project settings exercised through the installed public CLI and its outputs."""
from __future__ import annotations

from contextlib import closing
import http.client
import json
import os
from pathlib import Path
import socket
import shutil
import subprocess
import tempfile
import time
import urllib.request
import unittest
from html.parser import HTMLParser


REPO = Path(__file__).resolve().parent.parent
SUFFIX = ".exe" if os.name == "nt" else ""


class DocumentLanguage(HTMLParser):
    language = None

    def handle_starttag(self, tag, attrs):
        if tag == "html":
            self.language = dict(attrs).get("lang")


class ProjectConfigurationCliTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.binary = Path(os.environ.get(
            "CJDOC_BINARY", REPO / ("target/release/bin/main" + SUFFIX))).resolve()
        if not cls.binary.is_file():
            raise AssertionError("project configuration contracts require the built cjdoc CLI")

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="cjdoc-project-config-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.project = self.root / "project"
        (self.project / "src").mkdir(parents=True)
        (self.project / "cjpm.toml").write_text(
            '[package]\nname = "configuration_demo"\nversion = "0.1.0"\n'
            'cjc-version = "1.2.0"\noutput-type = "static"\n', encoding="utf-8")
        (self.project / "src/api.cj").write_text(
            "package configuration_demo\npublic func answer(): Int64 { 42 }\n", encoding="utf-8")
        self.cwd = self.root / "another-working-directory"
        self.cwd.mkdir()

    def configure(self, settings="", *, source_mode=True):
        if source_mode:
            settings += '\n[semantic]\nmode = "source"\n'
        (self.project / "cjdoc.toml").write_text(settings, encoding="utf-8")

    def invoke(self, *arguments, cwd=None):
        return subprocess.run([str(self.binary), *map(str, arguments)], cwd=cwd or self.cwd,
                              capture_output=True, text=True, timeout=120)

    def generate(self, *arguments):
        result = self.invoke("generate", "--project", self.project,
                             "--lint-profile", "off", "--no-cache", *arguments)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def read_document(self, path):
        document = json.loads(path.read_text(encoding="utf-8"))
        self.assertEqual(document["schemaVersion"], "cjdoc.doc-ir/19")
        self.assertIn("answer", {item["name"] for item in document["declarations"]})
        return document

    def test_short_generate_uses_project_relative_output_from_another_cwd(self):
        self.configure('[output]\nformats = ["json", "html"]\ndirectory = "published"\n'
                       'agent-full = true\nhtml-font-mono = "monospace"\n'
                       '[analysis]\naudience = "all"\njobs = 2\n')
        self.generate()
        output = self.project / "published"
        document = self.read_document(output / "docs.json")
        self.assertEqual(document["configuration"]["audience"], "all")
        self.assertTrue((output / "html/index.html").is_file())
        self.assertFalse((self.cwd / "published").exists())

    def test_cli_formats_replace_site_defaults_without_inheriting_html_requirements(self):
        self.configure('[output]\nformats = ["html", "markdown"]\ndirectory = "published"\n'
                       'agent-full = true\nhtml-font-sans = "sans-serif"\n'
                       '[analysis]\naudience = "package"\n')
        selected = self.root / "cli-output"
        self.generate("--format", "json", "--output", selected, "--audience", "all")
        document = self.read_document(selected / "docs.json")
        self.assertEqual(document["configuration"]["audience"], "all")
        self.assertFalse((selected / "html").exists())
        self.assertFalse((selected / "markdown").exists())
        self.assertFalse((self.project / "published").exists())
        explicit_html_flag = self.invoke("generate", "--project", self.project,
                                         "--format", "json", "--html-font-mono", "monospace")
        self.assertEqual(explicit_html_flag.returncode, 2)

    def test_stdout_and_check_do_not_inherit_site_output_defaults(self):
        self.configure('[output]\nformats = ["html"]\ndirectory = "published"\n'
                       'agent-full = true\nhtml-font-sans = "sans-serif"\n'
                       '[analysis]\nlint-profile = "off"\n')
        result = self.generate("--format", "json", "--stdout")
        document = json.loads(result.stdout)
        self.assertIn("answer", {item["name"] for item in document["declarations"]})
        checked = self.invoke("check", "--project", self.project, "--no-cache")
        self.assertEqual(checked.returncode, 0, checked.stderr)
        self.assertFalse((self.project / "published").exists())

    def test_comment_rule_exit_status_and_structure_errors(self):
        source = self.project / "src/api.cj"
        prefix = "package configuration_demo\n"
        declaration = "public func answer(): Unit {}\n"
        source.write_text(prefix + "/**\n * Answer.\n * @deprecated\n */\n" + declaration, encoding="utf-8")
        config = ('[comments.aliases]\nmaintainer2-team = "owner"\n'
                  '[[comments.fields]]\nid = "owner"\ntitle = "负责人"\n')
        rule = '[[comments.rules]]\nrequire = "owner"\nwhen-present = "deprecated"\n'
        args = ("check", "--project", self.project, "--no-cache", "--semantic", "source")
        self.configure(config + rule + 'severity = "warning"\n')
        warning = self.invoke(*args)
        self.assertEqual(warning.returncode, 0, warning.stderr)
        self.assertRegex(warning.stderr, r"warning\[CJDOC3142\]:.*answer.*owner.*deprecated")
        self.assertEqual(self.invoke(*args, "--deny-warnings").returncode, 1)
        self.configure(config + rule)
        error = self.invoke(*args)
        self.assertEqual(error.returncode, 1, error.stderr)
        self.assertIn("error[CJDOC3142]", error.stderr)
        off = self.invoke(*args, "--lint-profile", "off")
        self.assertEqual(off.returncode, 0, off.stderr)
        self.assertNotIn("CJDOC3142", off.stderr)

        source.write_text(prefix + "/**\n * Answer.\n * @owner[lang=en] invalid\n"
                          " * @maintainer2-team platform\n */\n" + declaration, encoding="utf-8")
        structure = self.invoke(*args, "--lint-profile", "off")
        self.assertEqual(structure.returncode, 1, structure.stderr)
        self.assertIn("error[CJDOC3140]", structure.stderr)
        self.assertIn("error[CJDOC3141]", structure.stderr)
        self.configure(config + '[[comments.rules]]\nrequire = "maintainer2-team"\n')
        invalid = self.invoke(*args, "--lint-profile", "off")
        self.assertEqual(invalid.returncode, 2, invalid.stderr)
        self.assertIn("CJDOC3139", invalid.stderr)

    def test_comment_alias_is_reinterpreted_after_a_source_cache_hit(self):
        source = self.project / "src/api.cj"
        source.write_text("package configuration_demo\n/**\n * Answer.\n"
                          " * @maintainer2-team platform\n */\n"
                          "public func answer(): Unit {}\n", encoding="utf-8")
        args = ("generate", "--project", self.project, "--format", "json", "--stdout",
                "--lint-profile", "off")
        cache = self.root / "source-cache"
        self.configure('[[comments.fields]]\nid = "owner"\ntitle = "负责人"\n')
        before = self.invoke(*args, "--cache-dir", cache)
        self.assertEqual(before.returncode, 0, before.stderr)
        self.assertEqual(json.loads(before.stdout)["metadata"]["fields"], [])
        self.assertTrue(any(path.is_file() for path in cache.rglob("*")), "source cache was not populated")
        self.configure('[comments.aliases]\nmaintainer2-team = "owner"\n'
                       '[[comments.fields]]\nid = "owner"\ntitle = "负责人"\n')
        cached = self.invoke(*args, "--cache-dir", cache)
        uncached = self.invoke(*args, "--no-cache")
        self.assertEqual(cached.returncode, 0, cached.stderr)
        self.assertEqual(uncached.returncode, 0, uncached.stderr)
        self.assertEqual(cached.stdout, uncached.stdout)
        field, = json.loads(cached.stdout)["metadata"]["fields"]
        self.assertEqual([use["values"] for use in field["uses"]], [["platform"]])

    def test_metadata_header_variants_preserve_groups_tags_and_translations(self):
        (self.project / "src/api.cj").write_text(
            "package configuration_demo\n/** Answer.\n * @group answers\n * @tag stable\n */\n"
            "public func answer(): Int64 { 42 }\n", encoding="utf-8")
        for separator, quote in ((".", ""), (".", '"'), (".", "'"),
                                 (" . ", ""), ("\t.\t", '"')):
            with self.subTest(separator=separator, quote=quote):
                def header(*parts):
                    return separator.join(quote + part + quote for part in parts)

                self.configure(
                    f'[{header("metadata")}]\n'
                    f'[[{header("metadata", "groups")}]]\n'
                    'package = "configuration_demo"\nid = "answers"\ntitle = "Answers"\n'
                    f'[{header("metadata", "groups", "titles")}]\nen = "Translated Answers"\n'
                    f'[[{header("metadata", "tags")}]]\nid = "stable"\ntitle = "Stable"\n'
                    f'[{header("metadata", "tags", "titles")}]\nen = "Translated Stable"\n')
                document = json.loads(self.generate("--format", "json", "--stdout").stdout)
                metadata = document["metadata"]
                self.assertEqual(
                    [(item["id"], item["title"], item["titles"]) for item in metadata["groups"]],
                    [("answers", "Answers", [{"language": "en", "title": "Translated Answers"}])])
                self.assertEqual(
                    [(item["id"], item["title"], item["titles"]) for item in metadata["tags"]],
                    [("stable", "Stable", [{"language": "en", "title": "Translated Stable"}])])
                checked = self.invoke("check", "--project", self.project,
                                      "--lint-profile", "off", "--no-cache")
                self.assertEqual(checked.returncode, 0, checked.stderr)

    def test_invalid_metadata_header_forms_cannot_replace_previous_output(self):
        self.configure()
        output = self.root / "metadata-stable-output"
        self.generate("--format", "json", "--output", output)
        accepted = (output / "docs.json").read_bytes()
        for settings in (
                '[["metadata"]]\n',
                '["metadata" . "groups"]\n',
                '["metadata" . "groups" . "titles"]\nen = "Orphan"\n',
                '[["metadata" . "tags" . "titles"]]\nen = "Wrong shape"\n',
                '["metadata" . "groups.titles"]\nen = "Not a dotted path"\n',
                '[["metadata"."tags"]]\nid = "stable"\ntitle = "First"\ntitle = "Second"\n',
                '[["metadata"."tags"]]\nid = "stable"\ntitle = "Stable"\n'
                '["metadata"."tags"."titles"]\nen = "First"\n'
                '["metadata" . "tags" . "titles"]\nen = "Second"\n'):
            with self.subTest(configuration=settings):
                self.configure(settings)
                result = self.invoke("generate", "--project", self.project,
                                     "--format", "json", "--output", output,
                                     "--lint-profile", "off", "--no-cache")
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertEqual((output / "docs.json").read_bytes(), accepted)

    def test_invalid_overridden_configuration_cannot_replace_previous_output(self):
        self.configure()
        output = self.root / "stable-output"
        self.generate("--format", "json", "--output", output)
        accepted = (output / "docs.json").read_bytes()
        (self.project / "docs").mkdir()
        (self.project / "docs/index.md").write_text("# Project\n", encoding="utf-8")
        invalid = [
            '[outputs]\ndirectory = "site"\n',
            '[analysis]\njob = 2\n',
            '[analysis]\njobs = 99\n',
            '[analysis]\naudience = "internal"\n',
            '[analysis]\nlint-profile = "loud"\n',
            '[analysis]\ninclude-path-dependencies = "yes"\n',
            '[analysis]\ncache-dir = "cache"\nno-cache = true\n',
            '[analysis]\njobs = 2\njobs = 3\n',
            '[output]\nformats = ["docx"]\n',
            '[output]\nformats = []\n',
            '[output]\nhtml-font-sans = "bad;font"\n',
            '[output]\nagent-full = "yes"\n',
            '[output]\ndirectory = "a"\n[output]\ndirectory = "b"\n',
            '[semantic]\nmode = "ast"\n',
            '[semantic]\nworker = "project-chosen-executable"\n',
            '[docs]\nindex = "docs/index.md"\nindx = "docs/index.md"\n',
        ]
        for quote in ('"""', "'''"):
            for table, assignment in (
                    ("semantic", 'mode = {quote}source{quote}'),
                    ("semantic", 'mode = {quote}invalid{quote}'),
                    ("semantic", 'unknown = {quote}ignored{quote}'),
                    ("output", 'directory = {quote}site{quote}'),
                    ("analysis", 'audience = {quote}all{quote}'),
                    ("analysis", 'jobs = {quote}invalid{quote}')):
                invalid.append(f"[{table}]\n{assignment.format(quote=quote)}\n")
            invalid.append(f"[semantic]\nmode = {quote}\nsource\n{quote}\n")
            invalid.append(f"[semantic]\nmode = {quote}source\n")
            invalid.append(f"unknown = {quote}ignored{quote}\n")
        for settings in invalid:
            with self.subTest(configuration=settings):
                self.configure(settings, source_mode=False)
                result = self.invoke("generate", "--project", self.project,
                                     "--semantic", "source", "--jobs", "1", "--audience", "external",
                                     "--lint-profile", "off", "--no-cache", "--format", "json",
                                     "--output", output)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertEqual((output / "docs.json").read_bytes(), accepted)

    def test_semantic_source_configuration_needs_no_cli_switch(self):
        self.configure('[output]\nformats = ["json"]\n')
        result = self.generate("--stdout")
        document = json.loads(result.stdout)
        self.assertFalse(any(item["name"] == "chir" for item in document["providers"]))
        self.assertNotIn("CJDOC21", result.stderr)
        for quote in ('"""', "'''"):
            self.configure(f"[semantic]\nmode = 'source' # {quote} comment only\n",
                           source_mode=False)
            commented = json.loads(self.generate("--stdout").stdout)
            self.assertFalse(any(item["name"] == "chir" for item in commented["providers"]))
        overridden = self.generate("--stdout", "--semantic", "chir", "--chir-worker",
                                   self.root / ("missing-worker" + SUFFIX))
        overridden_document = json.loads(overridden.stdout)
        self.assertIn("CJDOC2101", overridden.stderr)
        self.assertTrue(any(item["name"] == "chir" for item in overridden_document["providers"]))

    def test_disabled_cached_dependencies_do_not_inherit_a_cache_requirement(self):
        self.configure('[analysis]\ninclude-cached-dependencies = true\n'
                       'cjpm-cache = "not-prepared"\n')
        result = self.generate("--format", "json", "--stdout", "--no-include-cached-dependencies")
        document = json.loads(result.stdout)
        self.assertIn("answer", {item["name"] for item in document["declarations"]})
        self.assertNotIn("CJDOC1021", result.stderr)

    def test_cache_opt_in_updates_source_instead_of_replaying_an_old_capture(self):
        self.configure('[analysis]\nno-cache = true\n')
        cache = self.project / "target/cjdoc/cache"
        first = self.invoke("generate", "--project", self.project, "--format", "json", "--stdout",
                            "--lint-profile", "off")
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertIn("answer", {item["name"] for item in json.loads(first.stdout)["declarations"]})
        self.assertFalse(cache.exists())
        enabled = self.invoke("generate", "--project", self.project, "--format", "json", "--stdout",
                              "--lint-profile", "off", "--cache")
        self.assertEqual(enabled.returncode, 0, enabled.stderr)
        self.assertTrue(cache.is_dir())
        (self.project / "src/api.cj").write_text(
            "package configuration_demo\npublic func updated(): Int64 { 7 }\n", encoding="utf-8")
        changed = self.invoke("generate", "--project", self.project, "--format", "json", "--stdout",
                              "--lint-profile", "off", "--cache")
        self.assertEqual(changed.returncode, 0, changed.stderr)
        names = {item["name"] for item in json.loads(changed.stdout)["declarations"]}
        self.assertIn("updated", names)
        self.assertNotIn("answer", names)

    def test_named_cfg_overrides_preserve_other_configured_selectors(self):
        (self.project / "src/api.cj").write_text(
            'package configuration_demo\n'
            '@When[os == "Linux"]\npublic func linuxOnly(): Int64 { 1 }\n'
            '@When[os == "Windows"]\npublic func windowsOnly(): Int64 { 2 }\n'
            '@When[arch == "x86_64"]\npublic func x64Only(): Int64 { 3 }\n', encoding="utf-8")
        self.configure('[analysis]\ncfg = ["os=Linux", "arch=x86_64"]\n')
        configured = json.loads(self.generate("--format", "json", "--stdout").stdout)
        names = {item["name"] for item in configured["declarations"]}
        self.assertIn("linuxOnly", names)
        self.assertIn("x64Only", names)
        self.assertNotIn("windowsOnly", names)
        overridden = json.loads(self.generate("--format", "json", "--stdout",
                                               "--cfg", "os=Windows").stdout)
        names = {item["name"] for item in overridden["declarations"]}
        self.assertIn("windowsOnly", names)
        self.assertIn("x64Only", names)
        self.assertNotIn("linuxOnly", names)

    def test_relative_dependency_sources_and_explicit_cli_replacement(self):
        for directory, function in (("original-support", "originalSupport"),
                                    ("configured-support", "configuredSupport"),
                                    ("cli-support", "cliSupport")):
            library = self.root / directory
            (library / "src").mkdir(parents=True)
            (library / "cjpm.toml").write_text(
                '[package]\nname = "support"\nversion = "0.1.0"\n'
                'cjc-version = "1.2.0"\noutput-type = "static"\n', encoding="utf-8")
            (library / "src/api.cj").write_text(
                f"package support\npublic func {function}(): Int64 {{ 1 }}\n", encoding="utf-8")
        with (self.project / "cjpm.toml").open("a", encoding="utf-8") as manifest:
            manifest.write('\n[dependencies]\nsupport = {path = "../original-support"}\n')
        self.configure('[analysis]\ninclude-path-dependencies = true\n'
                       'dependency-sources = ["support=../configured-support"]\n')
        configured = json.loads(self.generate("--format", "json", "--stdout").stdout)
        names = {item["name"] for item in configured["declarations"]}
        self.assertIn("configuredSupport", names)
        self.assertNotIn("originalSupport", names)
        replaced = json.loads(self.generate("--format", "json", "--stdout", "--dependency-source",
                                             f"support={self.root / 'cli-support'}").stdout)
        names = {item["name"] for item in replaced["declarations"]}
        self.assertIn("cliSupport", names)
        self.assertNotIn("configuredSupport", names)
        self.configure('[analysis]\ninclude-path-dependencies = true\n')
        automatic = json.loads(self.generate("--format", "json", "--stdout").stdout)
        self.assertIn("originalSupport", {item["name"] for item in automatic["declarations"]})
        disabled = json.loads(self.generate("--format", "json", "--stdout",
                                             "--no-include-path-dependencies").stdout)
        names = {item["name"] for item in disabled["declarations"]}
        self.assertIn("answer", names)
        self.assertTrue(names.isdisjoint({"originalSupport", "configuredSupport", "cliSupport"}))

    def test_serve_reloads_config_removals_and_keeps_old_site_on_invalid_or_moved_output(self):
        output_settings = '[output]\nformats = ["json"]\ndirectory = "published"\n'
        self.configure(output_settings + '["metadata"]\n[analysis]\naudience = "all"\n')
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as reservation:
            reservation.bind(("localhost", 0))
            port = reservation.getsockname()[1]
        log = (self.root / "serve.log").open("w+", encoding="utf-8")
        self.addCleanup(log.close)
        process = subprocess.Popen(
            [str(self.binary), "serve", "--project", str(self.project), "--no-cache",
             "--lint-profile", "off", "--port", str(port)],
            cwd=self.cwd, stdout=subprocess.DEVNULL, stderr=log)
        self.addCleanup(self.stop_serve, process)
        url = f"http://localhost:{port}"

        def wait_status(predicate):
            deadline = time.monotonic() + 45
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    log.flush()
                    self.fail((self.root / "serve.log").read_text(encoding="utf-8"))
                try:
                    with urllib.request.urlopen(url + "/__cjdoc/status.json", timeout=2) as response:
                        status = json.load(response)
                    if predicate(status):
                        return status
                except (OSError, ValueError):
                    pass
                time.sleep(0.05)
            self.fail("serve did not publish the expected rebuild state")

        initial = wait_status(lambda status: status["successfulBuilds"] >= 1)
        document_path = self.project / "published/docs.json"
        first = self.read_document(document_path)
        self.assertEqual(first["configuration"]["audience"], "all")
        self.assertFalse(any(provider["name"] == "chir" for provider in first["providers"]))
        self.configure(output_settings, source_mode=False)
        changed = wait_status(lambda status: status["successfulBuilds"] > initial["successfulBuilds"])
        document = self.read_document(document_path)
        self.assertEqual(document["configuration"]["audience"], "external")
        self.assertTrue(any(provider["name"] == "chir" for provider in document["providers"]))
        with urllib.request.urlopen(url + "/index.html", timeout=5) as response:
            self.assertEqual(response.read(), (self.project / "published/html/index.html").read_bytes())

        api = "/configuration_demo/answer"
        query = "?origin=a%2Fb&empty="
        expected_body = (self.project / "published/html/configuration_demo/answer/index.html").read_bytes()
        with closing(http.client.HTTPConnection("localhost", port, timeout=5)) as client:
            for method in ("GET", "HEAD"):
                client.request(method, api + query)
                redirect = client.getresponse()
                self.assertEqual(redirect.status, 308)
                self.assertEqual(redirect.getheader("Location"), api + "/" + query)
                self.assertEqual(redirect.read(), b"")
                client.request(method, api + "/" + query)
                page = client.getresponse()
                self.assertEqual(page.status, 200)
                self.assertEqual(page.getheader("Content-Type"), "text/html; charset=utf-8")
                self.assertEqual(int(page.getheader("Content-Length")), len(expected_body))
                self.assertEqual(page.read(), expected_body if method == "GET" else b"")
            for path in ("/configuration_demo/missing/", "/symbols/", "/symbols"):
                client.request("GET", path)
                missing = client.getresponse()
                self.assertEqual(missing.status, 404)
                missing.read()
            client.request("GET", "/configuration_demo%2Fanswer")
            rejected = client.getresponse()
            self.assertEqual(rejected.status, 400)
            self.assertIsNone(rejected.getheader("Location"))
            rejected.read()
        accepted = document_path.read_bytes()
        self.configure('[output]\nformats = ["not-a-format"]\n', source_mode=False)
        invalid = wait_status(lambda status: status["builds"] > changed["builds"])
        self.assertEqual(invalid["status"], "error")
        self.assertEqual(document_path.read_bytes(), accepted)
        self.configure(output_settings.replace('"published"', '"another-output"'))
        moved = wait_status(lambda status: status["builds"] > invalid["builds"])
        self.assertEqual(moved["status"], "error")
        self.assertEqual(document_path.read_bytes(), accepted)
        self.assertFalse((self.project / "another-output/docs.json").exists())
        self.configure(output_settings + '[analysis]\naudience = "package"\n')
        recovered = wait_status(lambda status: status["successfulBuilds"] > changed["successfulBuilds"])
        self.assertEqual(recovered["status"], "ok")
        self.assertEqual(self.read_document(document_path)["configuration"]["audience"], "package")

    @staticmethod
    def stop_serve(process):
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=10)

    def test_i18n_default_and_explicit_cli_locale_select_actual_page_language(self):
        self.configure('[output]\nformats = ["html"]\ndirectory = "published"\n'
                       '[i18n]\ndefault-language = "en"\nlanguages = ["en", "zh-CN"]\n')
        self.generate()
        page = self.project / "published/html/index.html"
        parsed = DocumentLanguage()
        parsed.feed(page.read_text(encoding="utf-8"))
        self.assertEqual(parsed.language, "en")
        self.generate("--locale", "zh-CN")
        parsed = DocumentLanguage()
        parsed.feed(page.read_text(encoding="utf-8"))
        self.assertEqual(parsed.language, "zh-CN")

    def test_help_and_source_free_replay_ignore_invalid_project_configuration(self):
        self.configure()
        captured = self.generate("--format", "json", "--stdout")
        snapshot = self.root / "frozen.json"
        snapshot.write_text(captured.stdout, encoding="utf-8")
        self.configure('[outputs]\ndirectory = "bad"\n', source_mode=False)
        for command in (("generate",), ("check",), ("serve",), ("render",), ("diff",),
                        ("query",), ("mcp",), ("schema",), ("versions", "compose")):
            with self.subTest(help=command):
                result = self.invoke(*command, "--help", cwd=self.project)
                self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.invoke("unknown-command", "--help", cwd=self.project).returncode, 2)
        self.assertEqual(self.invoke("generate", cwd=self.project).returncode, 2)
        shutil.rmtree(self.project / "src")
        (self.project / "cjpm.toml").unlink()
        replay = self.root / "source-free-replay"
        result = self.invoke("render", "--input", snapshot, "--format", "json", "--format", "html",
                             "--agent-full", "--output", replay, cwd=self.project)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads((replay / "docs.json").read_text(encoding="utf-8")),
                         json.loads(captured.stdout))
        full_reference = (replay / "html/llms-full.txt").read_text(encoding="utf-8")
        self.assertIn("public func answer(): Int64", full_reference)


if __name__ == "__main__":
    unittest.main()
