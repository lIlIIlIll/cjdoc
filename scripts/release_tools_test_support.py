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
from scripts.verify_repository_inputs import GOLDEN_NAMES, SCHEMA_NAMES


PROJECT_ROOT = Path(__file__).resolve().parent.parent
MARKDOWN_COMMIT = "db4f9527944b589db8436669f1d255192388cee2"
YJSON_COMMIT = "bf65cbecd99ac25e7485f8db60990e94a04e57bc"
SDK_SHA256 = "1" * 64


class ReleaseToolsTestSupport:
    def git(self, repo: Path, *args: str) -> str:
        result = subprocess.run(
            ["git", "-c", "commit.gpgSign=false", "-c", "core.hooksPath=/dev/null",
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
        ):
            destination = root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(PROJECT_ROOT / relative, destination)
        for source in (PROJECT_ROOT / "vendor/yjson_algorithms/src").glob("*.cj"):
            shutil.copyfile(source, root / "vendor/yjson_algorithms/src" / source.name)
        shutil.copyfile(
            PROJECT_ROOT / "tests/fixtures/legacy-migration-v8.json",
            root / "tests/fixtures/legacy-migration-v8.json",
        )

        (root / "cjpm.toml").write_text(
            "[package]\nname=\"cjdoc\"\nversion=\"0.7.0\"\n"
            "[dependencies]\n"
            f"markdown={{git=\"https://github.com/lIlIIlIll/markdown.git\",commitId=\"{MARKDOWN_COMMIT}\",output-type=\"static\"}}\n"
            f"yjson={{git=\"https://github.com/lIlIIlIll/yjson.git\",commitId=\"{YJSON_COMMIT}\",output-type=\"static\"}}\n"
            "yjson_algorithms={path=\"vendor/yjson_algorithms\",output-type=\"static\"}\n",
            encoding="utf-8",
        )
        (root / "cjpm.lock").write_text(
            "version=0\n[requires]\n"
            f"markdown={{git=\"https://github.com/lIlIIlIll/markdown.git\",commitId=\"{MARKDOWN_COMMIT}\",output-type=\"static\"}}\n"
            f"yjson={{git=\"https://github.com/lIlIIlIll/yjson.git\",commitId=\"{YJSON_COMMIT}\",output-type=\"static\"}}\n",
            encoding="utf-8",
        )
        for name in SCHEMA_NAMES:
            shutil.copyfile(
                PROJECT_ROOT / "docs/schema" / f"{name}.schema.json",
                root / "docs/schema" / f"{name}.schema.json",
            )
        for version in (6, 7, 8):
            directory = root / f"tests/fixtures/golden-v{version}"
            directory.mkdir(parents=True)
            for name in GOLDEN_NAMES:
                shutil.copyfile(
                    PROJECT_ROOT / f"tests/fixtures/golden-v{version}/{name}.docs.json",
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

