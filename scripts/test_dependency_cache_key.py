#!/usr/bin/env python3
"""Tests for the Cangjie incremental dependency cache identity."""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from dependency_cache_key import (CACHE_PATHS, CACHE_SCHEMA, PRODUCT_OPTIONS,
                                  cache_identity, cache_key, github_outputs)  # noqa: E402


class DependencyCacheKeyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.repo = Path(self.temporary.name)
        (self.repo / "src").mkdir()
        (self.repo / "src/app.cj").write_text("package probe\n", encoding="utf-8")
        (self.repo / "tools/chir-worker/src").mkdir(parents=True)
        (self.repo / "tools/chir-worker/src/main.cj").write_text(
            "package worker\n", encoding="utf-8")
        (self.repo / "tools/chir-protocol/src").mkdir(parents=True)
        for relative, value in (
            ("cjpm.toml", '[package]\nname = "probe"\n'),
            ("cjpm.lock", "version = 1\n"),
            ("scripts/sts_compile_override.py", "OPTION = 'probe'\n"),
            ("scripts/apply_sts_override.py", "# probe\n"),
            ("scripts/with_sts_cjpm.sh", "# probe\n"),
            ("tools/chir-worker/cjpm.toml", '[package]\nname = "worker"\n'),
            ("tools/chir-worker/cjpm.lock", "version = 1\n"),
            ("scripts/check.sh", "# build entrypoint\n"),
            ("scripts/dependency_cache_key.py", "# probe cache key implementation\n"),
            ("vendor/yjson_algorithms/src/api.cj", "func api() {}\n"),
            ("tools/chir-protocol/src/protocol.cj", "func protocol() {}\n"),
        ):
            path = self.repo / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(value, encoding="utf-8")
        self.identity = dict(platform="Linux-X64", target="x86_64-unknown-linux-gnu",
                             compiler_fingerprint="compiler-sha", stdx_digest="stdx-sha",
                             sdk_version="1.2.0", cjpm_version="Cangjie Project Manager: 1.2.0")

    def key(self, **kwargs: str) -> str:
        identity = {**self.identity, **kwargs}
        return cache_key(self.repo, **identity)

    def test_same_inputs_produce_same_key(self) -> None:
        self.assertEqual(self.key(), self.key())
        self.assertIn(CACHE_SCHEMA, self.key())
        self.assertNotIn(str(self.repo), self.key())
        prefix, key = cache_identity(self.repo, **self.identity)
        output = github_outputs(prefix, key)
        self.assertIn("paths<<CJDOC_CACHE_PATHS", output)
        self.assertIn("\n".join(CACHE_PATHS), output)

    def test_cli_writes_restore_key_and_paths(self) -> None:
        output_path = self.repo / "github-output"
        script = Path(__file__).with_name("dependency_cache_key.py")
        result = subprocess.run(
            [sys.executable, str(script), "--repo", str(self.repo),
             "--platform", self.identity["platform"], "--target", self.identity["target"],
             "--compiler-fingerprint", self.identity["compiler_fingerprint"],
             "--stdx-digest", self.identity["stdx_digest"],
             "--sdk-version", self.identity["sdk_version"],
             "--cjpm-version", self.identity["cjpm_version"],
             "--github-output", str(output_path)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("restore-prefix=", result.stdout)
        self.assertIn("key=", result.stdout)
        self.assertIn("\n".join(CACHE_PATHS), result.stdout)
        self.assertEqual(output_path.read_text(encoding="utf-8"), result.stdout)

    def test_path_dependency_source_changes_dependency_identity(self) -> None:
        before_prefix, before = cache_identity(self.repo, **self.identity)
        path = self.repo / "vendor/yjson_algorithms/src/api.cj"
        path.write_text("func api() { 1 }\n", encoding="utf-8")
        after_prefix, after = cache_identity(self.repo, **self.identity)
        self.assertNotEqual(before_prefix, after_prefix)
        self.assertNotEqual(before, after)

    def test_lockfile_and_build_identity_changes_key(self) -> None:
        before = self.key()
        (self.repo / "cjpm.lock").write_text("version = 2\n", encoding="utf-8")
        self.assertNotEqual(before, self.key())
        self.assertNotEqual(self.key(), self.key(options=PRODUCT_OPTIONS + " -g"))
        self.assertNotEqual(self.key(), self.key(target="aarch64-unknown-linux-gnu"))
        self.assertNotEqual(self.key(), self.key(stdx_digest="other-stdx"))
        self.assertNotEqual(self.key(), self.key(platform="macOS-ARM64"))
        self.assertNotEqual(self.key(), self.key(cjpm_version="Cangjie Project Manager: 1.3.0"))
        self.assertNotEqual(self.key(), self.key(compiler_fingerprint="other-compiler"))
        self.assertNotEqual(self.key(), self.key(sdk_version="1.2.1"))

    def test_root_source_change_uses_dependency_restore_prefix(self) -> None:
        prefix, before = cache_identity(self.repo, **self.identity)
        (self.repo / "src/app.cj").write_text("package probe\n// changed\n", encoding="utf-8")
        changed_prefix, after = cache_identity(self.repo, **self.identity)
        self.assertEqual(prefix, changed_prefix)
        self.assertNotEqual(before, after)
        self.assertIn(f"restore-prefix={prefix}", github_outputs(prefix, before))

    def test_worker_source_does_not_invalidate_root_target_cache(self) -> None:
        prefix, key = cache_identity(self.repo, **self.identity)
        source = self.repo / "tools/chir-worker/src/main.cj"
        source.write_text("package worker\n// changed\n", encoding="utf-8")
        changed_prefix, changed_key = cache_identity(self.repo, **self.identity)
        self.assertEqual(prefix, changed_prefix)
        self.assertEqual(key, changed_key)


if __name__ == "__main__":
    unittest.main()
