#!/usr/bin/env python3
from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from scripts import with_stdx


class WithStdxTest(unittest.TestCase):
    @staticmethod
    def make_sidecar(directory: Path, names: tuple[str, ...]) -> Path:
        sidecar = directory / "stdx"
        sidecar.mkdir()
        for name in names:
            (sidecar / name).write_bytes(name.encode("utf-8"))
        return sidecar

    def test_authenticates_chir_static_artifacts_and_digest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            sidecar = self.make_sidecar(
                Path(temporary), ("stdx.chir.cjo", "libstdx.chir.a")
            )
            digest, files = with_stdx.authenticate_stdx(
                sidecar, with_stdx.REQUIRED_STATIC_ARTIFACTS
            )
            self.assertTrue(digest)
            self.assertEqual(
                {file.name for file in files}, set(with_stdx.REQUIRED_STATIC_ARTIFACTS)
            )


    def test_dynamic_mode_does_not_require_static_dependency(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            sidecar = self.make_sidecar(
                Path(temporary), ("stdx.chir.cjo", "libstdx.chir.so")
            )
            digest, _ = with_stdx.authenticate_stdx(
                sidecar, with_stdx.REQUIRED_DYNAMIC_ARTIFACTS
            )
            self.assertTrue(digest)
            self.assertEqual(with_stdx.parse_options(["--variant", "dynamic"]), ("dynamic", False))
            self.assertEqual(with_stdx.parse_options(["--print-env"]), ("static", True))
    def test_configured_sidecar_is_used_without_rewriting(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            sidecar = self.make_sidecar(
                Path(temporary), ("stdx.chir.cjo", "libstdx.chir.a")
            )
            with patch.dict(with_stdx.os.environ, {"CANGJIE_STDX_PATH": str(sidecar)}):
                self.assertEqual(
                    with_stdx.stdx_candidates(Path("unused"), "static", "unknown-target"),
                    [sidecar.resolve()],
                )

    def test_bundle_candidates_match_the_compiler_target(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            bundle = Path(temporary)
            cangjie = bundle / "cangjie"
            compiler = cangjie / "bin" / "cjc"
            compiler.parent.mkdir(parents=True)
            compiler.touch()
            linux_sidecar = bundle / "linux_x86_64_cjnative" / "static" / "stdx"
            wrong_sidecar = bundle / "windows_x86_64_cjnative" / "static" / "stdx"
            linux_sidecar.mkdir(parents=True)
            wrong_sidecar.mkdir(parents=True)
            with patch.dict(with_stdx.os.environ, {}, clear=True):
                self.assertEqual(
                    with_stdx.stdx_candidates(compiler, "static", "x86_64-unknown-linux-gnu"),
                    [linux_sidecar.resolve()],
                )
if __name__ == "__main__":
    unittest.main()
