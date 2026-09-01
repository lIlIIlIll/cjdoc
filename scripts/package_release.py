#!/usr/bin/env python3
"""Create byte-reproducible cjdoc release archives with an internal manifest."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tarfile
import tempfile
import tomllib
import zipfile

sys.dont_write_bytecode = True

try:
    from .verify_release_package import verify_archive
    from .install_cangjie_sdk import validate_cached_sdk_root
    from .safe_output_root import safe_output_directory, safe_output_file, safe_regular_file
    from .worktree_identity import exact_worktree_identity
except ImportError:  # Direct script execution.
    from verify_release_package import verify_archive
    from install_cangjie_sdk import validate_cached_sdk_root
    from safe_output_root import safe_output_directory, safe_output_file, safe_regular_file
    from worktree_identity import exact_worktree_identity


COMMIT = re.compile(r"^[0-9a-f]{40}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
SEMVER = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
SCHEMA_FILES = (
    "doc-ir.schema.json",
    "doc-ir-v6.schema.json",
    "doc-ir-v7.schema.json",
    "doc-ir-v8.schema.json",
    "diagnostics.schema.json",
    "cfg-matrix.schema.json",
    "search-index.schema.json",
    "api-surface.schema.json",
    "documentation-coverage.schema.json",
)


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def resolve_binary(value: Path) -> Path:
    candidate = Path(os.path.abspath(os.fspath(value)))
    candidates = (candidate, Path(f"{candidate}.exe"))
    for executable in candidates:
        try:
            executable.lstat()
        except FileNotFoundError:
            continue
        return safe_regular_file(executable, description="cjdoc binary")
    raise ValueError(f"cjdoc binary does not exist: {candidate}")


def verify_binary_version(binary: Path, version: str) -> None:
    try:
        result = subprocess.run(
            [str(binary), "--version"], text=True, capture_output=True,
            check=False, timeout=30,
        )
    except subprocess.TimeoutExpired as error:
        raise ValueError("binary --version timed out") from error
    if result.returncode != 0 or result.stdout.strip() != f"cjdoc {version}":
        raise ValueError("binary --version does not match cjpm.toml")


def verify_source_commit(repo: Path, expected: str) -> dict[str, object]:
    try:
        identity = exact_worktree_identity(repo, expected)
    except ValueError as error:
        raise ValueError(f"release package source identity failed: {error}") from error
    if Path(str(identity["root"])) != repo.resolve():
        raise ValueError("release package repository must be the Git top-level")
    return identity


def committed_file(repo: Path, source_commit: str, relative: str) -> bytes:
    tree = subprocess.run(
        ["git", "-C", str(repo), "ls-tree", "-z", source_commit, "--", relative],
        capture_output=True, check=False,
    )
    if tree.returncode != 0:
        raise ValueError(f"cannot inspect committed release payload: {relative}")
    entry = tree.stdout.rstrip(b"\0")
    if not entry or b"\0" in entry:
        raise ValueError(f"release payload is missing from source commit: {relative}")
    metadata, separator, name = entry.partition(b"\t")
    fields = metadata.split()
    if separator != b"\t" or name.decode("utf-8", "strict") != relative or \
            len(fields) != 3 or fields[0] not in (b"100644", b"100755") or fields[1] != b"blob":
        raise ValueError(f"release payload is not a regular committed file: {relative}")
    result = subprocess.run(
        ["git", "-C", str(repo), "show", f"{source_commit}:{relative}"],
        capture_output=True, check=False,
    )
    if result.returncode != 0:
        raise ValueError(f"cannot read committed release payload: {relative}")
    return result.stdout


def committed_package_version(repo: Path, source_commit: str) -> str:
    try:
        manifest = tomllib.loads(
            committed_file(repo, source_commit, "cjpm.toml").decode("utf-8")
        )
    except UnicodeDecodeError as error:
        raise ValueError("committed cjpm.toml is not UTF-8") from error
    version = manifest.get("package", {}).get("version")
    if not isinstance(version, str) or not SEMVER.fullmatch(version):
        raise ValueError("committed cjpm.toml package version must be a stable three-part SemVer")
    return version


def collect_payload(repo: Path, binary: Path, windows: bool, version: str,
                    platform_name: str, source_commit: str,
                    sdk_version: str, sdk_sha256: str) -> dict[str, tuple[bytes, int]]:
    executable_name = "cjdoc.exe" if windows else "cjdoc"
    payload: dict[str, tuple[bytes, int]] = {
        executable_name: (binary.read_bytes(), 0o755),
        "README.md": (committed_file(repo, source_commit, "README.md"), 0o644),
        "LICENSE": (committed_file(repo, source_commit, "LICENSE"), 0o644),
        "THIRD_PARTY_NOTICES.md": (
            committed_file(repo, source_commit, "THIRD_PARTY_NOTICES.md"), 0o644),
        "licenses/markdown-MIT.txt": (
            committed_file(repo, source_commit, "third_party/licenses/markdown-LICENSE"), 0o644),
        "licenses/yjson-Apache-2.0.txt": (
            committed_file(repo, source_commit, "vendor/yjson_algorithms/LICENSE"), 0o644),
    }
    for schema_name in SCHEMA_FILES:
        relative = f"docs/schema/{schema_name}"
        payload[relative] = (committed_file(repo, source_commit, relative), 0o644)
    manifest = {
        "schemaVersion": "cjdoc.release-package/2",
        "version": version,
        "platform": platform_name,
        "sourceCommit": source_commit,
        "runtime": {
            "requiresCangjieSdk": True,
            "sdkVersion": sdk_version,
            "sdkArchiveSha256": sdk_sha256,
        },
        "files": {
            name: {"sha256": sha256_bytes(content), "size": len(content)}
            for name, (content, _) in sorted(payload.items())
        },
    }
    manifest_bytes = (json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode()
    payload["release-manifest.json"] = (manifest_bytes, 0o644)
    return payload


def write_zip(path: Path, root_name: str, payload: dict[str, tuple[bytes, int]]) -> None:
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, (content, mode) in sorted(payload.items()):
            info = zipfile.ZipInfo(f"{root_name}/{name}", date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 3
            info.external_attr = (stat.S_IFREG | mode) << 16
            archive.writestr(info, content, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)


def write_tar_gz(path: Path, root_name: str, payload: dict[str, tuple[bytes, int]]) -> None:
    with path.open("wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0, compresslevel=9) as zipped:
            with tarfile.open(fileobj=zipped, mode="w", format=tarfile.USTAR_FORMAT) as archive:
                for name, (content, mode) in sorted(payload.items()):
                    info = tarfile.TarInfo(f"{root_name}/{name}")
                    info.size = len(content)
                    info.mode = mode
                    info.mtime = 0
                    info.uid = 0
                    info.gid = 0
                    info.uname = ""
                    info.gname = ""
                    archive.addfile(info, io.BytesIO(content))


def build_archive(repo: Path, binary: Path, platform_name: str, output: Path,
                  *, source_commit: str, sdk_version: str, sdk_sha256: str) -> Path:
    if not COMMIT.fullmatch(source_commit):
        raise ValueError("source commit must be a lowercase 40-hex commit")
    verify_source_commit(repo, source_commit)
    version = committed_package_version(repo, source_commit)
    if not SHA256.fullmatch(sdk_sha256):
        raise ValueError("SDK archive SHA-256 must be lowercase 64-hex")
    if not sdk_version:
        raise ValueError("SDK version is missing")
    windows = platform_name.startswith("windows-")
    extension = ".zip" if windows else ".tar.gz"
    output = safe_output_directory(repo, output, create=True)
    asset = output / f"cjdoc-{version}-{platform_name}{extension}"
    checksum = asset.with_name(f"{asset.name}.sha256")
    # A failed rebuild must not leave a prior package that can be mistaken for
    # evidence from this attempt. Validate both exact paths before removing either.
    safe_output_file(asset, description="release package")
    safe_output_file(checksum, description="release package checksum")
    asset.unlink(missing_ok=True)
    checksum.unlink(missing_ok=True)
    verify_source_commit(repo, source_commit)
    root_name = f"cjdoc-{version}"
    payload = collect_payload(repo, binary, windows, version, platform_name,
                              source_commit, sdk_version, sdk_sha256)
    verify_source_commit(repo, source_commit)
    with tempfile.NamedTemporaryFile(dir=output, prefix=f".{asset.name}.", delete=False) as stream:
        temporary = Path(stream.name)
    temporary_checksum: Path | None = None
    asset_published = False
    try:
        if windows:
            write_zip(temporary, root_name, payload)
        else:
            write_tar_gz(temporary, root_name, payload)
        digest = sha256_file(temporary)
        verify_source_commit(repo, source_commit)
        with tempfile.NamedTemporaryFile(
            "w", encoding="ascii", newline="\n", dir=output,
            prefix=f".{checksum.name}.", delete=False,
        ) as stream:
            stream.write(f"{digest}  {asset.name}\n")
            temporary_checksum = Path(stream.name)
        os.replace(temporary, asset)
        asset_published = True
        os.replace(temporary_checksum, checksum)
        temporary_checksum = None
        verify_source_commit(repo, source_commit)
    except BaseException:
        if asset_published:
            asset.unlink(missing_ok=True)
            checksum.unlink(missing_ok=True)
        raise
    finally:
        temporary.unlink(missing_ok=True)
        if temporary_checksum is not None:
            temporary_checksum.unlink(missing_ok=True)
    return asset


def main() -> int:
    repo = Path(__file__).resolve().parent.parent
    configured_sdk_root = os.environ.get("CANGJIE_SDK_ROOT")
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, default=repo / "target/release/bin/main")
    parser.add_argument("--platform", required=True,
                        choices=("linux-x64", "windows-x64", "macos-arm64"))
    parser.add_argument("--output", type=Path, default=repo / "target/release-package")
    parser.add_argument("--source-commit", default=os.environ.get("CJDOC_RELEASE_COMMIT"))
    parser.add_argument("--sdk-version", required=True)
    parser.add_argument("--sdk-sha256", required=True)
    parser.add_argument("--sdk-root", type=Path,
                        default=Path(configured_sdk_root) if configured_sdk_root else None)
    args = parser.parse_args()
    try:
        binary = resolve_binary(args.binary)
        if args.source_commit is None:
            raise ValueError("--source-commit or CJDOC_RELEASE_COMMIT is required")
        if not COMMIT.fullmatch(args.source_commit):
            raise ValueError("source commit must be a lowercase 40-hex commit")
        verify_source_commit(repo, args.source_commit)
        version = committed_package_version(repo, args.source_commit)
        if args.sdk_root is None:
            raise ValueError("--sdk-root or CANGJIE_SDK_ROOT is required")
        if not SHA256.fullmatch(args.sdk_sha256):
            raise ValueError("SDK archive SHA-256 must be lowercase 64-hex")
        if not args.sdk_version:
            raise ValueError("SDK version is missing")
        validate_cached_sdk_root(args.sdk_root, args.sdk_sha256)
        verify_binary_version(binary, version)
        asset = build_archive(
            repo, binary, args.platform, args.output,
            source_commit=args.source_commit,
            sdk_version=args.sdk_version,
            sdk_sha256=args.sdk_sha256,
        )
        package_evidence = verify_archive(
            asset, args.platform, version, args.sdk_version, args.sdk_sha256,
            args.source_commit, smoke=True, repository=repo,
            sdk_root=args.sdk_root, sdk_marker_verified=True,
        )
    except (OSError, ValueError, tomllib.TOMLDecodeError,
            tarfile.TarError, zipfile.BadZipFile) as error:
        parser.error(str(error))
    print(json.dumps({
        "asset": str(asset),
        "sha256": sha256_file(asset),
        "checksum": str(asset.with_name(f"{asset.name}.sha256")),
        "verification": package_evidence,
    }, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
