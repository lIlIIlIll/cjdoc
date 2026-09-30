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
        sidecar.mkdir(parents=True)
        for name in names:
            (sidecar / name).write_bytes(name.encode("utf-8"))
        return sidecar

    def test_authenticates_chir_static_artifacts_and_digest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            sidecar = self.make_sidecar(
                Path(temporary),
                ("stdx.chir.cjo", "libstdx.chir.a", "libflatbuffers.a"),
            )
            digest, files = with_stdx.authenticate_stdx(
                sidecar, with_stdx.REQUIRED_STATIC_ARTIFACTS
            )
            self.assertTrue(digest)
            self.assertEqual(
                {file.name for file in files}, set(with_stdx.REQUIRED_STATIC_ARTIFACTS)
            )

    def test_static_sidecar_rejects_missing_flatbuffers(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            sidecar = self.make_sidecar(
                Path(temporary), ("stdx.chir.cjo", "libstdx.chir.a")
            )
            with self.assertRaises(SystemExit):
                with_stdx.authenticate_stdx(
                    sidecar, with_stdx.required_artifacts("static", "x86_64-unknown-linux-gnu")
                )

    def test_dynamic_mode_requires_target_specific_library(self) -> None:
        platforms = {
            "x86_64-unknown-linux-gnu": "libstdx.chir.so",
            "aarch64-apple-darwin": "libstdx.chir.dylib",
            "x86_64-w64-mingw32": "stdx.chir.dll",
        }
        with tempfile.TemporaryDirectory() as temporary:
            for index, (target, library) in enumerate(platforms.items()):
                sidecar = self.make_sidecar(
                    Path(temporary) / str(index), ("stdx.chir.cjo", library)
                )
                digest, files = with_stdx.authenticate_stdx(
                    sidecar, with_stdx.required_artifacts("dynamic", target)
                )
                self.assertTrue(digest)
                self.assertEqual(
                    {file.name for file in files}, {"stdx.chir.cjo", library}
                )
            self.assertEqual(
                with_stdx.parse_options(["--variant", "dynamic"]), ("dynamic", False)
            )
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
