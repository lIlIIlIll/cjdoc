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

    def test_authenticates_static_artifacts_and_digest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            sidecar = self.make_sidecar(
                Path(temporary), with_stdx.REQUIRED_STATIC_ARTIFACTS
            )
            digest, files = with_stdx.authenticate_stdx(
                sidecar, with_stdx.REQUIRED_STATIC_ARTIFACTS
            )
            self.assertTrue(digest)
            self.assertEqual(
                {file.name for file in files}, set(with_stdx.REQUIRED_STATIC_ARTIFACTS)
            )

    def test_static_link_options_support_bundled_and_external_dependencies(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            sidecar = self.make_sidecar(
                Path(temporary), with_stdx.REQUIRED_STATIC_ARTIFACTS
            )
            options, digest = with_stdx.static_link_options(
                sidecar, "x86_64-unknown-linux-gnu"
            )
            self.assertEqual(options, "-lstdc++ -lgcc_s")
            self.assertEqual(digest, "")

            flatbuffers = sidecar / "libflatbuffers.a"
            flatbuffers.write_bytes(b"flatbuffers")
            options, digest = with_stdx.static_link_options(
                sidecar, "x86_64-unknown-linux-gnu"
            )
            self.assertIn(str(flatbuffers), options)
            self.assertEqual(digest, with_stdx.file_digest(flatbuffers))

    def test_dynamic_mode_does_not_require_static_dependency(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            sidecar = self.make_sidecar(
                Path(temporary), with_stdx.REQUIRED_DYNAMIC_ARTIFACTS
            )
            digest, _ = with_stdx.authenticate_stdx(
                sidecar, with_stdx.REQUIRED_DYNAMIC_ARTIFACTS
            )
            self.assertTrue(digest)
            self.assertEqual(with_stdx.parse_options(["--variant", "dynamic"]), ("dynamic", False))
            self.assertEqual(with_stdx.parse_options(["--print-env"]), ("static", True))


if __name__ == "__main__":
    unittest.main()
