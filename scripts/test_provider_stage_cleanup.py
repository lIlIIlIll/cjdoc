"""Run the provider stage's real Bash cleanup without invoking the compiler."""
from __future__ import annotations

import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

from scripts.release_build_parameters import usable_shell

ROOT = Path(__file__).resolve().parent.parent
SHELL = usable_shell()


def shell_function(name: str) -> str:
    source = (ROOT / "scripts/check.sh").read_text(encoding="utf-8")
    match = re.search(rf"^{re.escape(name)}\(\) [{{(]\n.*?^[}})]\n", source, re.M | re.S)
    if match is None:
        raise AssertionError(f"missing check.sh function: {name}")
    return match.group(0)


@unittest.skipUnless(SHELL, "no usable POSIX shell")
class ProviderCleanupTest(unittest.TestCase):
    def invoke(self, *, exit_code: int = 0, outputs: str = "directories", existing: str = "", check_outer: bool = False):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            repo = base / "repo with spaces"
            project = repo / "tests/fixtures/projects/provider_plugin"
            project.mkdir(parents=True)
            unrelated = project / "keep.txt"
            unrelated.write_bytes(b"unrelated")
            target, cache = project / "target", project / "build-script-cache"
            if existing:
                entry = target if existing.startswith("target") else cache
                if existing.endswith("directory"):
                    entry.mkdir()
                    (entry / "keep.txt").write_bytes(b"preexisting")
                else:
                    entry.write_bytes(b"preexisting")
            trace = base / "trace.txt"
            prelude = """set -euo pipefail
repo="$PROBE_REPO"
python_cmd="$PROBE_PYTHON"
require_identity() { printf '%s\\n' identity >> "$PROBE_TRACE"; }
cjpm() {
    printf '%s\\n' "$*" >> "$PROBE_TRACE"
    "$python_cmd" - <<'PY'
import os
from pathlib import Path
kind = os.environ["PROBE_OUTPUTS"]
if kind != "none":
    Path("build-script-cache").mkdir()
if kind == "directories":
    Path("target").mkdir()
elif kind == "file":
    Path("target").write_bytes(b"unexpected file")
PY
    return "$PROBE_EXIT"
}
"""
            body = (prelude + shell_function("remove_owned_outputs")
                    + shell_function("stage_provider") + shell_function("dispatch_stage"))
            environment = dict(os.environ, PROBE_REPO=repo.as_posix(),
                               PROBE_PYTHON=Path(sys.executable).as_posix(),
                               PROBE_TRACE=trace.as_posix(), PROBE_EXIT=str(exit_code),
                               PROBE_OUTPUTS=outputs, PYTHONDONTWRITEBYTECODE="1")
            if check_outer:
                body += ("provider_project=outer_project\n"
                         "provider_build_cache=outer_cache\nprovider_target=outer_target\n"
                         "dispatch_stage provider\n"
                         '[[ "$provider_project" == outer_project ]]\n'
                         '[[ "$provider_build_cache" == outer_cache ]]\n'
                         '[[ "$provider_target" == outer_target ]]\n'
                         "if declare -F cleanup_provider >/dev/null; then exit 72; fi\n")
            else:
                body += "dispatch_stage provider\n"
            result = subprocess.run([SHELL, "-c", body], env=environment,
                                    text=True, capture_output=True)
            state = {"targetExists": target.exists(), "cacheExists": cache.exists(),
                     "unrelated": unrelated.read_bytes(),
                     "targetFile": target.read_bytes() if target.is_file() else None,
                     "preexisting": (entry / "keep.txt").read_bytes()
                         if existing.endswith("directory") else None}
            return result, trace.read_text().splitlines(), state

    def test_failed_command_preserves_exit_and_removes_only_its_outputs(self):
        result, trace, state = self.invoke(exit_code=37)
        self.assertEqual(result.returncode, 37, result.stderr)
        self.assertNotIn("unbound variable", result.stderr)
        self.assertFalse(state["targetExists"])
        self.assertFalse(state["cacheExists"])
        self.assertEqual(state["unrelated"], b"unrelated")
        self.assertEqual(trace, ["identity", "run --build-args --jobs 1"])

    def test_failure_before_output_creation_preserves_exit(self):
        result, _, state = self.invoke(exit_code=37, outputs="none")
        self.assertEqual(result.returncode, 37, result.stderr)
        self.assertFalse(state["targetExists"])
        self.assertFalse(state["cacheExists"])

    def test_success_removes_owned_outputs(self):
        result, _, state = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(state["targetExists"])
        self.assertFalse(state["cacheExists"])
        self.assertEqual(state["unrelated"], b"unrelated")

    def test_success_keeps_provider_scope_inside_the_subshell(self):
        result, _, state = self.invoke(check_outer=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(state["targetExists"])
        self.assertFalse(state["cacheExists"])
        self.assertEqual(state["unrelated"], b"unrelated")

    def test_preexisting_directories_are_refused_and_preserved(self):
        for existing in ("target-directory", "cache-directory"):
            with self.subTest(existing=existing):
                result, trace, state = self.invoke(existing=existing)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(state["preexisting"], b"preexisting")
                self.assertEqual(trace, ["identity"])

    def test_preexisting_file_is_refused_and_preserved(self):
        result, trace, state = self.invoke(existing="target-file")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(state["targetFile"], b"preexisting")
        self.assertEqual(trace, ["identity"])

    def test_cleanup_failure_does_not_replace_the_original_failure(self):
        result, _, state = self.invoke(exit_code=37, outputs="file")
        self.assertEqual(result.returncode, 37, result.stderr)
        self.assertIn("owned build output is not a directory", result.stderr)
        self.assertEqual(state["targetFile"], b"unexpected file")
        self.assertEqual(state["unrelated"], b"unrelated")

    def test_cleanup_refuses_an_unexpected_file(self):
        result, _, state = self.invoke(outputs="file")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("owned build output is not a directory", result.stderr)
        self.assertEqual(state["targetFile"], b"unexpected file")
        self.assertEqual(state["unrelated"], b"unrelated")


if __name__ == "__main__":
    unittest.main()
