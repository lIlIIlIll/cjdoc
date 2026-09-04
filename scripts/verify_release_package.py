#!/usr/bin/env python3
"""Inspect and safely smoke-test one cjdoc release archive."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import zipfile

try:
    from . import release_archive_reader as _archive_reader
    from .install_cangjie_sdk import validate_cached_sdk_root
    from .release_archive_reader import (
        ArchiveMember,
        checked_size,
        is_manifest_candidate,
        read_member_stream,
        safe_member_name,
        sha256_bytes,
        sha256_file,
    )
    from .release_package_contracts import (
        COMMIT,
        MAX_ARCHIVE_SIZE,
        MAX_MANIFEST_SIZE,
        MAX_MEMBERS,
        MAX_MEMBER_SIZE,
        MAX_TOTAL_SIZE,
        REPOSITORY_PAYLOAD,
        SCHEMA_PAYLOAD,
        SEMVER,
        SHA256,
    )
    from .release_package_payload import (
        _inside,
        extract_members,
        inspect_archive as _inspect_archive,
        verify_repository_payload,
    )
    from .safe_output_root import lexical_absolute
    from .strict_json import strict_loads
except ImportError:  # Direct script execution.
    import release_archive_reader as _archive_reader
    from install_cangjie_sdk import validate_cached_sdk_root
    from release_archive_reader import (
        ArchiveMember,
        checked_size,
        is_manifest_candidate,
        read_member_stream,
        safe_member_name,
        sha256_bytes,
        sha256_file,
    )
    from release_package_contracts import (
        COMMIT,
        MAX_ARCHIVE_SIZE,
        MAX_MANIFEST_SIZE,
        MAX_MEMBERS,
        MAX_MEMBER_SIZE,
        MAX_TOTAL_SIZE,
        REPOSITORY_PAYLOAD,
        SCHEMA_PAYLOAD,
        SEMVER,
        SHA256,
    )
    from release_package_payload import (
        _inside,
        extract_members,
        inspect_archive as _inspect_archive,
        verify_repository_payload,
    )
    from safe_output_root import lexical_absolute
    from strict_json import strict_loads

def _sync_archive_limits() -> None:
    for name in (
        "MAX_MEMBERS", "MAX_ARCHIVE_SIZE", "MAX_MEMBER_SIZE", "MAX_TOTAL_SIZE",
    ):
        setattr(_archive_reader, name, globals()[name])


def read_archive(path: Path, *, expected_format: str | None = None) -> dict[str, ArchiveMember]:
    _sync_archive_limits()
    return _archive_reader.read_archive(path, expected_format=expected_format)


def inspect_archive(path: Path, platform_name: str, version: str,
                    sdk_version: str, sdk_sha256: str,
                    source_commit: str) -> tuple[dict[str, object], dict[str, ArchiveMember], str]:
    _sync_archive_limits()
    return _inspect_archive(
        path, platform_name, version, sdk_version, sdk_sha256, source_commit
    )

def powershell_sdk_environment_invocation(setup: Path) -> tuple[list[str], dict[str, str]]:
    script = (
        "$ErrorActionPreference='Stop'; . $env:CJDOC_SDK_SETUP; $values=@{}; "
        "Get-ChildItem Env: | ForEach-Object {$values[$_.Name]=$_.Value}; "
        "$values | ConvertTo-Json -Compress"
    )
    return ([
        "powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
        "-Command", script,
    ], {**os.environ, "CJDOC_SDK_SETUP": str(setup)})


def declared_sdk_environment(root: Path) -> tuple[dict[str, str], dict[str, str]]:
    root = root.resolve()
    if os.name == "nt":
        powershell_setup = root / "envsetup.ps1"
        batch_setup = root / "envsetup.bat"
        if powershell_setup.is_file():
            command, child_environment = powershell_sdk_environment_invocation(
                powershell_setup
            )
            result = subprocess.run(
                command,
                text=True, capture_output=True, check=False, timeout=30,
                env=child_environment,
            )
            if result.returncode != 0:
                raise ValueError(
                    "declared SDK environment setup failed: " +
                    (result.stderr or result.stdout).strip()
                )
            try:
                raw_environment = strict_loads(
                    result.stdout, description="declared SDK environment"
                )
            except ValueError as error:
                raise ValueError("declared SDK environment output is invalid JSON") from error
            if not isinstance(raw_environment, dict):
                raise ValueError("declared SDK environment is not an object")
            environment = {str(key): str(value) for key, value in raw_environment.items()}
        elif batch_setup.is_file():
            result = subprocess.run(
                ["cmd.exe", "/d", "/s", "/c",
                 'call "%CJDOC_SDK_SETUP%" >nul && set'],
                text=True, capture_output=True, check=False, timeout=30,
                env={**os.environ, "CJDOC_SDK_SETUP": str(batch_setup)},
            )
            if result.returncode != 0:
                raise ValueError(
                    "declared SDK environment setup failed: " +
                    (result.stderr or result.stdout).strip()
                )
            environment = {}
            for line in result.stdout.splitlines():
                key, separator, value = line.partition("=")
                if separator and key:
                    environment[key] = value
        else:
            raise ValueError("declared Windows SDK root omits envsetup.ps1/envsetup.bat")
    else:
        setup = root / "envsetup.sh"
        if not setup.is_file():
            raise ValueError("declared SDK root omits envsetup.sh")
        result = subprocess.run(
            ["bash", "--noprofile", "--norc", "-c",
             'set -eo pipefail; source "$1"; set -u; env -0',
             "cjdoc-sdk-env", str(setup)],
            capture_output=True, check=False, timeout=30,
        )
        if result.returncode != 0:
            raise ValueError(
                "declared SDK environment setup failed: " +
                (result.stderr or result.stdout).decode("utf-8", "replace").strip()
            )
        environment: dict[str, str] = {}
        for entry in result.stdout.split(b"\0"):
            if not entry:
                continue
            key, separator, value = entry.partition(b"=")
            if not separator:
                raise ValueError("declared SDK environment output is malformed")
            environment[key.decode("utf-8", "strict")] = value.decode("utf-8", "strict")

    def environment_value(name: str) -> str | None:
        expected = name.upper()
        return next((value for key, value in environment.items()
                     if key.upper() == expected), None)

    configured_home = environment_value("CANGJIE_HOME")
    if configured_home is None or Path(configured_home).resolve() != root:
        raise ValueError("declared SDK environment resolves a different CANGJIE_HOME")
    path_value = environment_value("PATH") or ""
    tools: dict[str, str] = {}
    for name in ("cjc", "cjpm"):
        resolved = shutil.which(name, path=path_value)
        if resolved is None:
            raise ValueError(f"declared SDK environment cannot resolve {name}")
        tool = Path(resolved).resolve()
        if not _inside(root, tool):
            raise ValueError(f"declared SDK environment resolves {name} outside the SDK root")
        tools[name] = tool.relative_to(root).as_posix()
    return environment, tools


def run_smoke(binary: Path, version: str,
              environment: dict[str, str]) -> dict[str, str]:
    commands = (("version", [str(binary), "--version"]),
                ("schema", [str(binary), "schema", "list"]))
    evidence: dict[str, str] = {}
    for name, command in commands:
        try:
            result = subprocess.run(
                command, text=True, capture_output=True, check=False, timeout=30,
                env=environment,
            )
        except subprocess.TimeoutExpired as error:
            raise ValueError(f"extracted binary {name} smoke timed out") from error
        if result.returncode != 0:
            raise ValueError(
                f"extracted binary {name} smoke failed ({result.returncode}): " +
                (result.stderr or result.stdout).strip()
            )
        output = result.stdout.strip()
        if name == "version" and output != f"cjdoc {version}":
            raise ValueError("extracted binary --version does not match the package")
        if name == "schema" and "doc-ir-v8" not in output.splitlines():
            raise ValueError("extracted binary schema list omits doc-ir-v8")
        evidence[name] = output
    return evidence


def verify_archive(path: Path, platform_name: str, version: str,
                   sdk_version: str, sdk_sha256: str, source_commit: str,
                   smoke: bool, repository: Path | None = None,
                   sdk_root: Path | None = None,
                   sdk_marker_verified: bool = False) -> dict[str, object]:
    path = lexical_absolute(path)
    archive_sha256 = sha256_file(path)
    manifest, members, executable_name = inspect_archive(
        path, platform_name, version, sdk_version, sdk_sha256, source_commit
    )
    if repository is not None:
        verify_repository_payload(members, repository, source_commit)
    smoke_evidence: dict[str, str] | None = None
    sdk_environment_evidence: dict[str, str] | None = None
    if smoke:
        if sdk_root is None:
            raise ValueError("release package smoke requires --sdk-root")
        validated_root = sdk_root.resolve() if sdk_marker_verified else \
            validate_cached_sdk_root(sdk_root, sdk_sha256)
        environment, sdk_environment_evidence = declared_sdk_environment(validated_root)
        with tempfile.TemporaryDirectory(prefix="cjdoc-package-smoke-") as temporary:
            expected_format = "zip" if platform_name.startswith("windows-") else "gzip-tar"
            root = extract_members(
                path, expected_format, Path(temporary), f"cjdoc-{version}", members
            )
            smoke_evidence = run_smoke(root / executable_name, version, environment)
    if sha256_file(path) != archive_sha256:
        raise ValueError("release archive changed during verification")
    return {
        "schemaVersion": "cjdoc.release-package-verification/1",
        "archive": path.name,
        "archiveSha256": archive_sha256,
        "manifest": manifest,
        "smoke": smoke_evidence,
        "sdkEnvironment": sdk_environment_evidence,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--platform", required=True,
                        choices=("linux-x64", "windows-x64", "macos-arm64"))
    parser.add_argument("--version", required=True)
    parser.add_argument("--sdk-version", required=True)
    parser.add_argument("--sdk-sha256", required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--repository", type=Path)
    parser.add_argument("--sdk-root", type=Path)
    parser.add_argument("--inspect-only", action="store_true")
    args = parser.parse_args()
    try:
        evidence = verify_archive(
            lexical_absolute(args.archive), args.platform, args.version,
            args.sdk_version, args.sdk_sha256, args.source_commit,
            smoke=not args.inspect_only, repository=args.repository,
            sdk_root=args.sdk_root,
        )
    except (OSError, ValueError, tarfile.TarError, zipfile.BadZipFile) as error:
        parser.error(str(error))
    print(json.dumps(evidence, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
