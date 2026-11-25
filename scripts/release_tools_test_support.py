from __future__ import annotations

import json
import os
from pathlib import Path
import py_compile
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock
import zipfile

from scripts import package_release
from scripts import perf_gate
from scripts import real_repository_smoke
from scripts import safe_output_root
from scripts import source_identity
from scripts import strict_json
from scripts import verify_release
from scripts import verify_release_package
from scripts import verify_remote_tag
from scripts import verify_repository_inputs
from scripts import worktree_identity
from scripts.release_package_contracts import API_COMMENT_SKILL_FILES
from scripts.showcase_inputs import source_inputs
from scripts.sts_compile_override import PRODUCT_OPTIONS
from scripts.verify_repository_inputs import (
    CURRENT_GOLDEN_VERSION,
    GOLDEN_NAMES,
    SCHEMA_NAMES,
)


PROJECT_ROOT = Path(__file__).resolve().parent.parent
MARKDOWN_COMMIT = "db4f9527944b589db8436669f1d255192388cee2"
YJSON_COMMIT = "54b4965dee0f0b96710cbc678ec5ec9a126b055c"
SDK_SHA256 = "1" * 64


class ReleaseToolsTestSupport:
    def git(self, repo: Path, *args: str) -> str:
        result = subprocess.run(
            # A detached maintenance process can recreate .git entries while
            # TemporaryDirectory removes this short-lived repository.
            ["git", "-c", "maintenance.auto=false", "-c", "gc.auto=0",
             "-c", "commit.gpgSign=false", "-c", "core.hooksPath=/dev/null",
             "-c", "core.autocrlf=false",
             "-C", str(repo), *args], text=True, capture_output=True, check=True
        )
        return result.stdout.strip()

    def make_release_repo(self, root: Path, *, initialize_git: bool = True) -> tuple[Path, str | None]:
        (root / "docs/schema").mkdir(parents=True)
        (root / "tests/perf").mkdir(parents=True)
        (root / "tests/fixtures").mkdir(parents=True)
        (root / "third_party/licenses").mkdir(parents=True)
        (root / "vendor/yjson_algorithms/src").mkdir(parents=True)
        (root / "README.md").write_text("# fixture\n", encoding="utf-8")
        (root / "LICENSE").write_text("fixture project license\n", encoding="utf-8")
        for relative in (
            "THIRD_PARTY_NOTICES.md",
            "third_party/licenses/markdown-LICENSE",
            "vendor/yjson_algorithms/LICENSE",
            "vendor/yjson_algorithms/UPSTREAM.md",
            "vendor/yjson_algorithms/cjpm.toml",
            "vendor/yjson_algorithms/vendor-manifest.toml",
            "cjdoc.toml",
            "site/showcase-baseline.json",
            "scripts/requirements-showcase.txt",
            *API_COMMENT_SKILL_FILES,
            *source_inputs(),
        ):
            destination = root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(PROJECT_ROOT / relative, destination)
        for source in (PROJECT_ROOT / "vendor/yjson_algorithms/src").glob("*.cj"):
            shutil.copyfile(source, root / "vendor/yjson_algorithms/src" / source.name)

        (root / "cjpm.toml").write_text(
            "[package]\nname=\"cjdoc\"\nversion=\"0.7.0\"\n"
            "[dependencies]\n"
            f"markdown={{git=\"https://github.com/lIlIIlIll/markdown.git\",commitId=\"{MARKDOWN_COMMIT}\",output-type=\"static\"}}\n"
            f"yjson={{git=\"https://github.com/lIlIIlIll/yjson.git\",commitId=\"{YJSON_COMMIT}\",output-type=\"static\"}}\n"
            "yjson_algorithms={path=\"vendor/yjson_algorithms\",output-type=\"static\"}\n"
            "cjdoc_chir_protocol={path=\"tools/chir-protocol\",output-type=\"static\"}\n",
            encoding="utf-8",
        )
        (root / "cjpm.lock").write_text(
            "version=0\n[requires]\n"
            f"markdown={{git=\"https://github.com/lIlIIlIll/markdown.git\",commitId=\"{MARKDOWN_COMMIT}\",output-type=\"static\"}}\n"
            f"yjson={{git=\"https://github.com/lIlIIlIll/yjson.git\",commitId=\"{YJSON_COMMIT}\",output-type=\"static\"}}\n"
            "yjson_macros={git=\"https://github.com/lIlIIlIll/yjson_macros.git\",commitId=\"fec0adce41f73d037d876cbac7a28aee8108bb5c\"}\n",
            encoding="utf-8",
        )
        for name in SCHEMA_NAMES:
            shutil.copyfile(
                PROJECT_ROOT / "docs/schema" / f"{name}.schema.json",
                root / "docs/schema" / f"{name}.schema.json",
            )
        directory = root / f"tests/fixtures/golden-v{CURRENT_GOLDEN_VERSION}"
        directory.mkdir(parents=True)
        for name in GOLDEN_NAMES:
            shutil.copyfile(
                PROJECT_ROOT / f"tests/fixtures/golden-v{CURRENT_GOLDEN_VERSION}/{name}.docs.json",
                directory / f"{name}.docs.json",
            )
        (root / "tests/perf/baseline.json").write_text(json.dumps({
            "schemaVersion": "cjdoc.perf-baseline/1",
            "state": "frozen",
            "purpose": "hard-ceiling",
        }), encoding="utf-8")

        if not initialize_git:
            return root, None
        self.git(root, "init", "-q")
        self.git(root, "config", "user.name", "Fixture")
        self.git(root, "config", "user.email", "fixture@example.invalid")
        self.git(root, "config", "commit.gpgSign", "false")
        self.git(root, "config", "tag.gpgSign", "false")
        self.git(root, "add", "-f", ".")
        self.git(root, "commit", "-q", "-m", "fixture")
        self.git(root, "tag", "v0.7.0")
        return root, self.git(root, "rev-parse", "HEAD")

    def make_candidate_receipt(self, repo: Path, binary: Path, commit: str,
                               platform_name: str = "linux-x64", *,
                               sdk_version: str = "1.1.3", stdx_version: str = "1.2.0",
                               stdx_sha256: str = "2" * 64) -> dict:
        """Synthetic current-format receipt for package contract tests only."""
        worker = self.make_worker(binary)
        return self.make_candidate_receipt_for(
            repo, binary, worker, commit, platform_name, sdk_version=sdk_version,
            stdx_version=stdx_version, stdx_sha256=stdx_sha256)

    @staticmethod
    def make_worker(binary: Path, content: bytes | None = None) -> Path:
        """Stage a CHIR worker beside a fixture CLI, as the real gate does."""
        name = "chir-worker-main.exe" if binary.name.endswith(".exe") else "chir-worker-main"
        worker = binary.parent / name
        if content is None:
            worker.write_text(
                "#!/usr/bin/env python3\n"
                "import sys\n"
                "if sys.argv[1:] == ['--version']:\n"
                "    print('cjdoc-chir-worker 0.7.0')\n"
                "elif sys.argv[1:] == ['--protocol-version']:\n"
                "    print('cjdoc-chir-worker/3')\n"
                "else:\n"
                "    raise SystemExit(2)\n",
                encoding="utf-8",
            )
        else:
            worker.write_bytes(content)
        worker.chmod(0o755)
        return worker

    def make_candidate_receipt_for(self, repo: Path, binary: Path, worker: Path,
                                   commit: str,
                                   platform_name: str = "linux-x64", *,
                                   sdk_version: str = "1.1.3", stdx_version: str = "1.2.0",
                                   stdx_sha256: str = "2" * 64) -> dict:
        """A `/2` receipt carrying both accepted executables and their sealed build."""
        main_digest = verify_release_package.sha256_file(binary)
        worker_digest = verify_release_package.sha256_file(worker)
        return {
            "schemaVersion": "cjdoc.release-candidate/2",
            "source": {"tag": "v0.7.0", "releaseVersion": "0.7.0", "commit": commit,
                       "tree": self.git(repo, "rev-parse", "HEAD^{tree}"),
                       "dirty": False, "worktreeSha256": "a" * 64},
            "platform": {"id": platform_name,
                         "os": "Windows" if platform_name.startswith("windows-") else "Linux",
                         "architecture": "x86_64",
                         "compilerTarget": "x86_64-pc-windows" if platform_name.startswith("windows-")
                         else "x86_64-unknown-linux-gnu"},
            "toolchain": {"sdkVersion": sdk_version, "sdkArchiveSha256": SDK_SHA256,
                          "stdxVersion": stdx_version, "stdxArchiveSha256": stdx_sha256,
                          "compilerVersion": f"Cangjie Compiler: {sdk_version}", "cjpmVersion": sdk_version,
                          "stdxDigest": "b" * 64, "toolchainFingerprint": "c" * 64},
            "build": {"command": ["cjpm", "build", "-i", "--jobs", "1"],
                      "effectiveCompileOptions": list(PRODUCT_OPTIONS),
                      "buildConfigurationSha256": "d" * 64},
            "binary": {"path": "target/release/bin/main",
                       "sha256": main_digest,
                       "size": binary.stat().st_size, "versionOutput": "cjdoc 0.7.0"},
            "worker": {"path": f"target/release/bin/{worker.name}",
                       "sha256": worker_digest, "size": worker.stat().st_size,
                       "versionOutput": "cjdoc-chir-worker 0.7.0",
                       "protocolVersion": "cjdoc-chir-worker/3"},
            "buildManifest": {
                "path": "target/ci-build/build-manifest.json",
                "sha256": "f" * 64,
                "mainBinary": {"path": "target/release/bin/main",
                               "sha256": main_digest, "size": binary.stat().st_size},
                "workerBinary": {"path": f"target/release/bin/{worker.name}",
                                 "sha256": worker_digest, "size": worker.stat().st_size},
            },
            "execution": {"runId": "1", "runAttempt": 1,
                          "job": f"release-candidate ({platform_name})"},
            "gates": {"release-gate": "e" * 64},
        }

    @staticmethod
    def make_fake_sdk(root: Path) -> Path:
        tools = root / "tools/bin"
        tools.mkdir(parents=True)
        for name in ("cjc", "cjpm"):
            tool = tools / name
            tool.write_text("#!/usr/bin/env sh\nexit 0\n", encoding="utf-8")
            tool.chmod(0o755)
        envsetup = root / "envsetup.sh"
        envsetup.write_text(
            "#!/usr/bin/env bash\n"
            "_cjdoc_sdk_root=\"$(cd \"$(dirname \"${BASH_SOURCE[0]}\")\" && pwd)\"\n"
            "export CANGJIE_HOME=\"${_cjdoc_sdk_root}\"\n"
            "export PATH=\"${_cjdoc_sdk_root}/tools/bin:${PATH}\"\n",
            encoding="utf-8",
        )
        return root
