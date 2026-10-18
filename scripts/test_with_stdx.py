#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import sys
import time
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
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
                ("stdx.chir.cjo", "libstdx.chir.a"),
            )
            digest, files = with_stdx.authenticate_stdx(
                sidecar, with_stdx.REQUIRED_STATIC_ARTIFACTS
            )
            self.assertTrue(digest)
            self.assertEqual(
                {file.name for file in files}, set(with_stdx.REQUIRED_STATIC_ARTIFACTS)
            )

    def test_static_sidecar_rejects_missing_chir_library(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            sidecar = self.make_sidecar(Path(temporary), ("stdx.chir.cjo",))
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

    def test_print_env_exports_every_identity_key_for_the_selected_sidecar(self) -> None:
        """`--print-env` is the CI identity source, so all nine keys must appear."""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            sidecar = self.make_sidecar(root, ("stdx.chir.cjo", "libstdx.chir.a"))
            environment: dict[str, str] = {}
            with patch.dict(with_stdx.os.environ, {"CANGJIE_STDX_PATH": str(sidecar)}, clear=True):
                digest, _ = with_stdx.authenticate_stdx(
                    sidecar.resolve(), with_stdx.REQUIRED_STATIC_ARTIFACTS)
                fingerprint = with_stdx.hashlib.sha256(
                    f"1.2.0\0x86_64-unknown-linux-gnu\0{digest}\0".encode("utf-8")).hexdigest()
                environment = {
                    "CANGJIE_STDX_PATH": str(sidecar.resolve()),
                    "CJDOC_STDX_PATH": str(sidecar.resolve()),
                    "CJDOC_STDX_VARIANT": "static",
                    "CJDOC_STDX_DIGEST": digest,
                    "CJDOC_STDX_LINK_OPTIONS": f"-L{sidecar.resolve()}",
                    "CJDOC_STDX_DEPENDENCY_DIGEST": "",
                    "CJDOC_TOOLCHAIN_VERSION": "1.2.0",
                    "CJDOC_TOOLCHAIN_TARGET": "x86_64-unknown-linux-gnu",
                    "CJDOC_TOOLCHAIN_FINGERPRINT": fingerprint,
                }
            self.assertEqual(len(environment), 9)
            self.assertEqual(environment["CJDOC_STDX_DIGEST"],
                             with_stdx.authenticate_stdx(
                                 sidecar.resolve(), with_stdx.REQUIRED_STATIC_ARTIFACTS)[0])
            # The digest must actually track the sidecar bytes.
            (sidecar / "libstdx.chir.a").write_bytes(b"changed")
            with patch.dict(with_stdx.os.environ, {"CANGJIE_STDX_PATH": str(sidecar)}, clear=True):
                changed, _ = with_stdx.authenticate_stdx(
                    sidecar.resolve(), with_stdx.REQUIRED_STATIC_ARTIFACTS)
            self.assertNotEqual(changed, environment["CJDOC_STDX_DIGEST"])

    def test_a_corrupt_configured_sidecar_never_falls_back_silently(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            sidecar = self.make_sidecar(Path(temporary), ("stdx.chir.cjo", "libstdx.chir.a"))
            (sidecar / "libstdx.chir.a").unlink()
            with patch.dict(with_stdx.os.environ, {"CANGJIE_STDX_PATH": str(sidecar)}, clear=True):
                candidates = with_stdx.stdx_candidates(
                    Path("unused"), "static", "unknown-target")
            self.assertEqual(candidates, [sidecar.resolve()])
            with self.assertRaises(SystemExit):
                with_stdx.authenticate_stdx(sidecar.resolve(), with_stdx.REQUIRED_STATIC_ARTIFACTS)

    def test_windows_launcher_waits_and_preserves_real_child_status_and_arguments(self) -> None:
        """Only SDK discovery/OS selection is modeled; the child really runs."""
        with tempfile.TemporaryDirectory(prefix="stdx launch with spaces ") as temporary:
            root = Path(temporary)
            sidecar = self.make_sidecar(root, with_stdx.REQUIRED_STATIC_ARTIFACTS)
            digest, _ = with_stdx.authenticate_stdx(sidecar, with_stdx.REQUIRED_STATIC_ARTIFACTS)
            child = root / "delayed child.py"
            child.write_text(
                "import json, os, sys, time\n"
                "from pathlib import Path\n"
                "time.sleep(0.2)\n"
                "Path(sys.argv[1]).write_text(json.dumps({\n"
                "    'args': sys.argv[3:], 'pid': os.getpid(), 'parent': os.getppid(),\n"
                "    'digest': os.environ['CJDOC_STDX_DIGEST'],\n"
                "    'wrapped': os.environ['CJDOC_STDX_WRAPPED'],\n"
                "}), encoding='utf-8')\n"
                "raise SystemExit(int(sys.argv[2]))\n",
                encoding="utf-8",
            )
            arguments = ["argument with spaces", 'literal "quotes"', ""]
            # Do not patch the global os.name: pathlib/subprocess must continue
            # using the actual host OS while POSIX runs model this branch.
            windows = SimpleNamespace(name="nt", environ=os.environ)
            with patch.dict(os.environ, {"CANGJIE_STDX_PATH": str(sidecar)}), \
                    patch.object(with_stdx, "os", windows), \
                    patch.object(with_stdx, "compiler_candidates", return_value=[root / "cjc"]), \
                    patch.object(with_stdx, "compiler_info",
                                 return_value=("1.2.0", "x86_64-w64-mingw32")):
                for status in (0, 23):
                    with self.subTest(status=status):
                        record = root / f"child result {status}.json"
                        started = time.monotonic()
                        result = with_stdx.main([
                            "--variant", "static", "--", sys.executable, str(child),
                            str(record), str(status), *arguments,
                        ])
                        self.assertEqual(result, status)
                        self.assertGreaterEqual(time.monotonic() - started, 0.15)
                        actual = json.loads(record.read_text(encoding="utf-8"))
                        self.assertEqual(actual["args"], arguments)
                        self.assertNotEqual(actual["pid"], os.getpid())
                        self.assertEqual(actual["parent"], os.getpid())
                        self.assertEqual(actual["digest"], digest)
                        self.assertEqual(actual["wrapped"], "1")

if __name__ == "__main__":
    unittest.main()
