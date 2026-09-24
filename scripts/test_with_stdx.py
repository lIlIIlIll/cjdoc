#!/usr/bin/env python3
from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

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


if __name__ == "__main__":
    unittest.main()
