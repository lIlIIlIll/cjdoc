"""Check manifest language options through the CLI and real CHIR worker."""
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parent.parent


@unittest.skipIf(os.name == "nt", "compiler argv capture requires a POSIX executable script")
class ChirCompilerOptionsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.binary = Path(os.environ.get("CJDOC_BINARY", REPO / "target/release/bin/main"))
        candidates = [REPO / "tools/chir-worker/target/release/bin/main",
                      cls.binary.parent / "chir-worker-main"]
        default_worker = next((path for path in candidates if path.is_file()), candidates[-1])
        cls.worker = Path(os.environ.get("CJDOC_CHIR_WORKER", default_worker))
        if not cls.binary.is_file() or not cls.worker.is_file():
            raise AssertionError("CHIR option contracts require built cjdoc and worker binaries")

    def generate(self, package_options, *, target_options="", dependencies=None):
        with tempfile.TemporaryDirectory(prefix="cjdoc-chir-options-") as directory:
            root = Path(directory).resolve()
            (root / "src").mkdir()
            (root / "src/api.cj").write_text(
                "package options\npublic func foo(value: Int64): Int64 { value }\n",
                encoding="utf-8")
            manifest = '[package]\nname = "options"\n' + package_options
            if dependencies is not None:
                (root / "dep/src").mkdir(parents=True)
                (root / "src/api.cj").write_text(
                    "package options\nimport dep.*\n"
                    "public func foo(value: Int64): Int64 { helper(value) }\n", encoding="utf-8")
                (root / "dep/src/api.cj").write_text(
                    "package dep\npublic func helper(value: Int64): Int64 { value }\n", encoding="utf-8")
                (root / "dep/cjpm.toml").write_text(
                    '[package]\nname = "dep"\n' + dependencies, encoding="utf-8")
                manifest += '\n[dependencies]\ndep = { path = "dep", output-type = "static" }\n'
            (root / "cjpm.toml").write_text(manifest + target_options, encoding="utf-8")
            compiler = root / "compiler"
            compiler.write_text(
                "#!/usr/bin/env python3\n"
                "import json, sys\nfrom pathlib import Path\n"
                "if sys.argv[1:] in (['-v'], ['--version']):\n"
                "    print('Cangjie Compiler: 1.2.0 (cjnative)')\n"
                "    print('Target: x86_64-unknown-linux-gnu')\n"
                "    sys.exit(0)\n"
                "log = Path(__file__).with_suffix('.jsonl')\n"
                "with log.open('a') as stream:\n"
                "    stream.write(json.dumps(sys.argv[1:]) + '\\n')\n"
                "sys.exit(1)\n", encoding="utf-8")
            compiler.chmod(0o700)
            dependency_options = ["--include-path-dependencies"] if dependencies is not None else []
            result = subprocess.run([
                str(self.binary), "generate", "--project", str(root),
                "--format", "json", "--stdout", "--no-cache", "--lint-profile", "off",
                "--semantic", "chir", "--chir-worker", str(self.worker), "--cjc", str(compiler),
                *dependency_options,
            ], capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stderr)
            document = json.loads(result.stdout)
            self.assertTrue(any(item["name"] == "foo" for item in document["declarations"]))
            log = compiler.with_suffix(".jsonl")
            calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            return document, result.stderr, calls

    def assert_forwarded(self, options, expected, *, dependencies=None):
        document, stderr, calls = self.generate(options, dependencies=dependencies)
        self.assertNotIn("CJDOC2102", stderr)
        self.assertIn("CJDOC2103", stderr)  # The recording compiler intentionally stops here.
        self.assertTrue(calls, stderr)
        for arguments in calls:
            forwarded = [arg for arg in arguments if arg in ("--experimental", "--enable-local-mode")]
            self.assertEqual(forwarded, expected)
            self.assertIn("--emit-chir=raw", arguments)
            self.assertEqual(arguments[arguments.index("--output-type") + 1], "staticlib")
        self.assertTrue(all(item["semantic"]["state"] == "unavailable"
                            for item in document["declarations"] if item["name"] == "foo"))

    def test_real_chir_keeps_standard_library_type_links(self):
        with tempfile.TemporaryDirectory(prefix="cjdoc-chir-stdlib-") as directory:
            root = Path(directory).resolve()
            (root / "src").mkdir()
            (root / "cjpm.toml").write_text('[package]\nname = "core_links"\n', encoding="utf-8")
            (root / "src/api.cj").write_text(
                "package core_links\n"
                "public func accept(number: Int64, text: String, values: Array<Int64>): Int64 { number }\n",
                encoding="utf-8")
            result = subprocess.run([
                str(self.binary), "generate", "--project", str(root), "--no-cache",
                "--format", "html", "--semantic", "chir", "--chir-worker", str(self.worker),
                "--lint-profile", "off",
            ], capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn("CJDOC21", result.stderr)
            output = root / "target/doc/html"
            document = json.loads((output / "agent/docs.json").read_text(encoding="utf-8"))
            function = next(item for item in document["declarations"] if item["name"] == "accept")
            number, text, array = [item["type"] for item in function["parameters"]]
            types = [(number, "#int64"), (text, "#struct-string"),
                     (array, "#struct-arrayt"), (array["arguments"][0], "#int64"),
                     (function["returnType"], "#int64")]
            html = "\n".join(page.read_text(encoding="utf-8") for page in (output / "symbols").glob("*.html"))
            for value, anchor in types:
                with self.subTest(type=value["spelling"]):
                    self.assertEqual(value["semanticState"], "resolved")
                    navigation = value["navigation"]
                    self.assertIsInstance(navigation, dict)
                    self.assertEqual(navigation["state"], "resolved")
                    self.assertEqual(navigation["matchLevel"], "manual")
                    self.assertTrue(navigation["url"].endswith(anchor), navigation)
                    self.assertIn('href="' + navigation["url"] + '"', html)

    def test_package_string_and_empty_override(self):
        self.assert_forwarded(
            'compile-option = "--experimental --enable-local-mode"\n'
            'override-compile-option = ""\n', ["--experimental", "--enable-local-mode"])

    def test_quoted_key_and_multiline_array(self):
        for key in ['"compile-option"', "'compile-option'", '"compile\\u002doption"']:
            with self.subTest(key=key):
                self.assert_forwarded(
                    key + ' = [\n "-O2", # ignored optimization flag\n'
                    ' "--experimental",\n "--enable-local-mode",\n]\n',
                    ["--experimental", "--enable-local-mode"])

    def test_nonempty_override_replaces_compile_options(self):
        self.assert_forwarded(
            'compile-option = "--experimental --enable-local-mode"\n'
            'override-compile-option = "-O2"\n', [])

    def test_override_options_are_forwarded(self):
        self.assert_forwarded(
            'compile-option = "-O2"\n'
            'override-compile-option = "--experimental --enable-local-mode"\n',
            ["--experimental", "--enable-local-mode"])

    def test_comments_do_not_enable_language_features(self):
        self.assert_forwarded('compile-option = "-O2" # --experimental --enable-local-mode\n', [])

    def test_duplicate_flags_are_forwarded_once(self):
        self.assert_forwarded(
            'compile-option = "--experimental --experimental --enable-local-mode"\n',
            ["--experimental", "--enable-local-mode"])

    def test_conflicting_options_still_reject_and_keep_source(self):
        for flag in ["-p alternate", "-B alternate", "--output-dir elsewhere", "--emit-chir=opt"]:
            for key in ["compile-option", "override-compile-option"]:
                with self.subTest(flag=flag, key=key):
                    _, stderr, calls = self.generate(f'{key} = "--experimental {flag}"\n')
                    self.assertIn("CJDOC2102", stderr)
                    self.assertEqual(calls, [])

    def test_target_language_options_are_not_applied_globally(self):
        _, stderr, calls = self.generate(
            'compile-option = "-O2"\n',
            target_options='\n[target.aarch64-apple-darwin]\ncompile-option = "--experimental"\n')
        self.assertIn("CJDOC2102", stderr)
        self.assertEqual(calls, [])

    def test_dependency_options_are_selected_per_module(self):
        # A dependency with a distinct language option must not inherit root flags.
        _, stderr, calls = self.generate(
            'compile-option = "--experimental"\n',
            dependencies='compile-option = "--enable-local-mode"\n')
        self.assertNotIn("unsupported compiler options", stderr)
        self.assertIn("CJDOC2103", stderr)
        self.assertTrue(calls, stderr)
        for arguments in calls:
            self.assertIn("--enable-local-mode", arguments)
            self.assertNotIn("--experimental", arguments)


if __name__ == "__main__":
    unittest.main()
