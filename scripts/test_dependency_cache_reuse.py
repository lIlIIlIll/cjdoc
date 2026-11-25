#!/usr/bin/env python3
"""Exercise cjpm's incremental dependency reuse and source invalidation."""
from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


class CjpmDependencyIncrementalTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.cjpm = shutil.which("cjpm")
        if cls.cjpm is None or shutil.which("cjc") is None:
            raise unittest.SkipTest("Cangjie SDK is not installed")

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="cjdoc-cjpm-incremental-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        dependency = self.root / ".cjpm/git/cache_dep"
        application = self.root / "app"
        (dependency / "src").mkdir(parents=True)
        (application / "src").mkdir(parents=True)
        (dependency / "cjpm.toml").write_text(
            '[package]\ncjc-version = "1.2.0"\nname = "cache_dep"\n'
            'version = "0.1.0"\noutput-type = "static"\n', encoding="utf-8")
        (application / "cjpm.toml").write_text(
            '[package]\ncjc-version = "1.2.0"\nname = "cache_app"\n'
            'version = "0.1.0"\noutput-type = "executable"\n\n'
            '[dependencies]\n"cache_dep" = { path = "../.cjpm/git/cache_dep", '
            'output-type = "static" }\n', encoding="utf-8")
        self.dependency_source = dependency / "src/dependency.cj"
        self.dependency_source.write_text(
            "package cache_dep\npublic func answer(): Int64 { 41 }\n", encoding="utf-8")
        self.application_source = application / "src/main.cj"
        self.application_source.write_text(
            "package cache_app\nimport cache_dep.*\n"
            "main(): Unit { println(answer()) }\n", encoding="utf-8")
        self.application = application

    def build(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [self.cjpm, "build", "-i", "--jobs", "1", "-V"],
            cwd=self.application, capture_output=True, text=True, timeout=180)

    def binary(self) -> Path:
        path = self.application / "target/release/bin/main"
        if os.name == "nt":
            path = path.with_suffix(".exe")
        return path

    def test_restored_cache_reuses_dependency_then_invalidates_source_change(self) -> None:
        clean = self.build()
        self.assertEqual(clean.returncode, 0, clean.stderr)
        self.assertIn("Compiling package `cache_dep`", clean.stdout)
        self.assertEqual(subprocess.run([self.binary()], capture_output=True,
                                        text=True).stdout.strip(), "41")

        hot = self.build()
        self.assertEqual(hot.returncode, 0, hot.stderr)
        self.assertNotIn("Compiling package `cache_dep`", hot.stdout)
        self.assertNotIn("Compiling package `cache_app`", hot.stdout)

        cache = self.root / "saved-cache"
        shutil.copytree(self.application / "target/release", cache / "target/release")
        shutil.copytree(self.root / ".cjpm/git", cache / ".cjpm/git")
        shutil.rmtree(self.application / "target")
        shutil.rmtree(self.root / ".cjpm")
        fresh_checkout_time = time.time() + 10
        for path in (self.application_source, self.application / "cjpm.toml"):
            os.utime(path, (fresh_checkout_time, fresh_checkout_time))
        shutil.copytree(cache / "target/release", self.application / "target/release")
        shutil.copytree(cache / ".cjpm/git", self.root / ".cjpm/git")

        restored = self.build()
        self.assertEqual(restored.returncode, 0, restored.stderr)
        self.assertNotIn("Compiling package `cache_dep`", restored.stdout)
        self.assertEqual(subprocess.run([self.binary()], capture_output=True,
                                        text=True).stdout.strip(), "41")
        self.application_source.write_text(
            "package cache_app\nimport cache_dep.*\n"
            "main(): Unit { println(answer() + 1) }\n", encoding="utf-8")
        changed_root_time = time.time() + 20
        os.utime(self.application_source, (changed_root_time, changed_root_time))
        changed_root = self.build()
        self.assertEqual(changed_root.returncode, 0, changed_root.stderr)
        self.assertNotIn("Compiling package `cache_dep`", changed_root.stdout)
        self.assertIn("Compiling package `cache_app`", changed_root.stdout)
        self.assertEqual(subprocess.run([self.binary()], capture_output=True,
                                        text=True).stdout.strip(), "42")

        self.dependency_source.write_text(
            "package cache_dep\npublic func answer(): Int64 { 42 }\n", encoding="utf-8")
        future = time.time() + 30
        os.utime(self.dependency_source, (future, future))
        changed = self.build()
        self.assertEqual(changed.returncode, 0, changed.stderr)
        self.assertIn("Compiling package `cache_dep`", changed.stdout)
        self.assertIn("Compiling package `cache_app`", changed.stdout)
        result = subprocess.run([self.binary()], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "43")


if __name__ == "__main__":
    unittest.main()
