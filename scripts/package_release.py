#!/usr/bin/env python3
"""Create byte-reproducible cjdoc release archives with an internal manifest."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
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
    from .install_cangjie_sdk import validate_combined_sdk_root
    from .release_package_contracts import (
        RELEASE_SEMVER,
        REPOSITORY_PAYLOAD,
        WORKER_PROTOCOL,
        WORKER_RECEIPT_KEYS,
        WORKER_VERSION_PREFIX,
        main_executable,
        release_version_from_tag,
        worker_executable,
    )
    from .safe_output_root import safe_output_directory, safe_output_file, safe_regular_file
    from .worktree_identity import exact_worktree_identity
except ImportError:  # Direct script execution.
    from verify_release_package import verify_archive
    from install_cangjie_sdk import validate_combined_sdk_root
    from release_package_contracts import (
        RELEASE_SEMVER,
        REPOSITORY_PAYLOAD,
        WORKER_PROTOCOL,
        WORKER_RECEIPT_KEYS,
        WORKER_VERSION_PREFIX,
        main_executable,
        release_version_from_tag,
        worker_executable,
    )
    from safe_output_root import safe_output_directory, safe_output_file, safe_regular_file
    from worktree_identity import exact_worktree_identity


COMMIT = re.compile(r"^[0-9a-f]{40}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
SEMVER = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")


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


def verify_candidate_receipt(receipt: dict, binary_content: bytes, worker_content: bytes,
                             platform_name: str,
                             source_commit: str, sdk_sha256: str,
                             stdx_sha256: str) -> tuple[str, str, str]:
    """Return (tag, tree, receipt digest) after binding the receipt to this package.

    The receipt is the only accepted proof that these exact bytes passed this
    platform's acceptance gates, so every identity it claims is re-checked here
    rather than trusted. Both executables are compared: a receipt that accepted
    one worker and a package that carries another is rejected, which is what
    stops a same-version worker from being shipped beside an accepted CLI.
    """
    if not isinstance(receipt, dict) or receipt.get("schemaVersion") != "cjdoc.release-candidate/2":
        raise ValueError("unexpected release candidate receipt schema")
    source = receipt.get("source")
    if not isinstance(source, dict) or not COMMIT.fullmatch(str(source.get("commit") or "")) or \
            not COMMIT.fullmatch(str(source.get("tree") or "")):
        raise ValueError("release candidate receipt must carry its full commit and tree")
    if source["commit"] != source_commit:
        raise ValueError("release candidate receipt is for a different source commit")
    if not isinstance(source.get("tag"), str) or not source["tag"]:
        raise ValueError("release candidate receipt must carry its release tag")
    platform = receipt.get("platform")
    if not isinstance(platform, dict) or platform.get("id") != platform_name:
        raise ValueError("release candidate receipt is for a different platform")
    toolchain = receipt.get("toolchain")
    if not isinstance(toolchain, dict) or toolchain.get("sdkArchiveSha256") != sdk_sha256:
        raise ValueError("release candidate receipt used a different SDK archive")
    if toolchain.get("stdxArchiveSha256") != stdx_sha256:
        raise ValueError("release candidate receipt used a different stdx archive")
    binary = receipt.get("binary")
    if not isinstance(binary, dict):
        raise ValueError("release candidate receipt omits its binary identity")
    actual = sha256_bytes(binary_content)
    if binary.get("sha256") != actual:
        raise ValueError("release candidate receipt does not describe the packaged binary")
    if binary.get("size") != len(binary_content):
        raise ValueError("release candidate receipt binary size does not match the package")
    worker = receipt.get("worker")
    if not isinstance(worker, dict) or set(worker) != WORKER_RECEIPT_KEYS:
        raise ValueError("release candidate receipt omits its CHIR worker identity")
    expected_worker = worker_executable(platform_name.startswith("windows-"))
    if not isinstance(worker.get("path"), str) or \
            PurePosixPath(worker["path"]).name != expected_worker:
        raise ValueError(
            f"release candidate worker must be {expected_worker} beside the packaged CLI")
    if not isinstance(worker.get("versionOutput"), str) or \
            not worker["versionOutput"].startswith(WORKER_VERSION_PREFIX):
        raise ValueError("release candidate worker version output is not a CHIR worker version")
    if not isinstance(worker.get("protocolVersion"), str) or \
            not WORKER_PROTOCOL.fullmatch(worker["protocolVersion"]):
        raise ValueError("release candidate worker protocol version is invalid")
    if worker.get("sha256") != sha256_bytes(worker_content):
        raise ValueError("release candidate receipt does not describe the packaged CHIR worker")
    if worker.get("size") != len(worker_content):
        raise ValueError("release candidate receipt worker size does not match the package")
    sealed = receipt.get("buildManifest")
    if not isinstance(sealed, dict):
        raise ValueError("release candidate receipt omits its sealed build manifest")
    for key in ("mainBinary", "workerBinary"):
        entry = sealed.get(key)
        if not isinstance(entry, dict) or entry.get("sha256") != (
                binary.get("sha256") if key == "mainBinary" else worker.get("sha256")):
            raise ValueError(
                "release candidate receipt is not bound to the build that produced its binaries")
    canonical = (json.dumps(receipt, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode()
    return source["tag"], source["tree"], sha256_bytes(canonical)


def resolve_worker_path(binary: Path, worker: Path | None, windows: bool) -> Path:
    """Return the packaged worker, defaulting to the CLI's sibling.

    The installed CLI looks for the companion in its own directory, so the
    default is also the only layout that works after installation.
    """
    return worker if worker is not None else binary.parent / worker_executable(windows)


def collect_payload(repo: Path, binary: Path, windows: bool, version: str,
                    platform_name: str, source_commit: str,
                    sdk_version: str, sdk_sha256: str,
                    stdx_version: str,
                    stdx_sha256: str,
                    candidate_receipt: dict,
                    *, worker: Path | None = None) -> dict[str, tuple[bytes, int]]:
    if not isinstance(stdx_version, str) or not SEMVER.fullmatch(stdx_version):
        raise ValueError("stdx version must be a stable three-part SemVer")
    if not isinstance(stdx_sha256, str) or not SHA256.fullmatch(stdx_sha256):
        raise ValueError("stdx archive SHA-256 must be lowercase 64-hex")
    worker = resolve_worker_path(binary, worker, windows)
    executable_name = main_executable(windows)
    worker_name = worker_executable(windows)
    executable_content = binary.read_bytes()
    worker_content = worker.read_bytes()
    payload: dict[str, tuple[bytes, int]] = {
        executable_name: (executable_content, 0o755),
        worker_name: (worker_content, 0o755),
    }
    for archive_name, repository_name in REPOSITORY_PAYLOAD.items():
        payload[archive_name] = (committed_file(repo, source_commit, repository_name), 0o644)
    runtime: dict[str, object] = {
        "requiresCangjieSdk": True,
        "sdkVersion": sdk_version,
        "sdkArchiveSha256": sdk_sha256,
        "requiresStdx": True,
        "stdxVersion": stdx_version,
        "stdxArchiveSha256": stdx_sha256,
    }
    tag, tree, receipt_digest = verify_candidate_receipt(
        candidate_receipt, executable_content, worker_content, platform_name,
        source_commit, sdk_sha256, stdx_sha256)
    accepted_worker = candidate_receipt["worker"]
    manifest = {
        "schemaVersion": "cjdoc.release-package/5",
        "version": version,
        "platform": platform_name,
        "sourceCommit": source_commit,
        "runtime": runtime,
        "executables": {"main": executable_name, "worker": worker_name},
        # The identity the acceptance gates observed, so the packaged worker can
        # be re-executed and compared instead of trusted by file name alone.
        "chirWorker": {"versionOutput": accepted_worker["versionOutput"],
                       "protocolVersion": accepted_worker["protocolVersion"]},
        "files": {
            name: {"sha256": sha256_bytes(content), "size": len(content)}
            for name, (content, _) in sorted(payload.items())
        },
        "releaseTag": tag,
        "sourceTree": tree,
        "candidateReceiptSha256": receipt_digest,
    }
    receipt_content = (json.dumps(candidate_receipt, ensure_ascii=False,
                                  sort_keys=True, indent=2) + "\n").encode()
    payload["release-candidate.json"] = (receipt_content, 0o644)
    manifest["files"]["release-candidate.json"] = {
        "sha256": sha256_bytes(receipt_content), "size": len(receipt_content)}
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


def _verify_receipt_against_worktree(receipt: dict, identity: dict[str, object],
                                     version: str) -> None:
    """Bind the receipt to the live source worktree before packing anything."""
    if not isinstance(receipt, dict) or receipt.get("schemaVersion") != "cjdoc.release-candidate/2":
        raise ValueError("unexpected release candidate receipt schema")
    source = receipt.get("source")
    if not isinstance(source, dict):
        raise ValueError("release candidate receipt omits its source identity")
    if source.get("commit") != identity["headCommit"] or source.get("tree") != identity["tree"]:
        raise ValueError("release candidate receipt is for a different source commit or tree")
    if source.get("dirty") is True:
        raise ValueError("release candidate receipt was produced from a dirty worktree")
    release_version = str(source.get("releaseVersion") or "")
    if release_version.split("-", 1)[0] != version:
        raise ValueError("release candidate receipt version does not match cjpm.toml")


def _require_adjacent_pair(binary: Path, worker: Path, windows: bool) -> None:
    """Require the two packaged executables to be a sibling pair of real files.

    The installed CLI locates its worker from its own directory, so a package
    that carried the pair in different places would install a broken default.
    """
    expected_worker = worker_executable(windows)
    if not worker.is_file() or worker.is_symlink():
        raise ValueError(f"release CHIR worker is missing or not a regular file: {worker}")
    if worker.name != expected_worker or worker.parent != binary.parent:
        raise ValueError(
            f"release CHIR worker must be {expected_worker} in the CLI's directory")


def build_archive(repo: Path, binary: Path, platform_name: str, output: Path,
                  *, source_commit: str, sdk_version: str, sdk_sha256: str,
                  release_version: str,
                  stdx_version: str,
                  stdx_sha256: str,
                  candidate_receipt: dict,
                  worker: Path | None = None) -> Path:
    if not COMMIT.fullmatch(source_commit):
        raise ValueError("source commit must be a lowercase 40-hex commit")
    identity = verify_source_commit(repo, source_commit)
    version = committed_package_version(repo, source_commit)
    if not RELEASE_SEMVER.fullmatch(release_version):
        raise ValueError("release version must be a SemVer release version")
    if release_version.split("-", 1)[0] != version:
        raise ValueError(
            f"release version {release_version!r} does not match package version {version!r}"
        )
    if not SHA256.fullmatch(sdk_sha256):
        raise ValueError("SDK archive SHA-256 must be lowercase 64-hex")
    if not sdk_version:
        raise ValueError("SDK version is missing")
    _verify_receipt_against_worktree(candidate_receipt, identity, version)
    windows = platform_name.startswith("windows-")
    worker = resolve_worker_path(binary, worker, windows)
    _require_adjacent_pair(binary, worker, windows)
    payload = collect_payload(repo, binary, windows,
                              release_version, platform_name, source_commit,
                              sdk_version, sdk_sha256, stdx_version, stdx_sha256,
                              candidate_receipt, worker=worker)
    extension = ".zip" if windows else ".tar.gz"
    output = safe_output_directory(repo, output, create=True)
    asset = output / f"cjdoc-{release_version}-{platform_name}{extension}"
    checksum = asset.with_name(f"{asset.name}.sha256")
    # A failed rebuild must not leave a prior package that can be mistaken for
    # evidence from this attempt. Validate both exact paths before removing either.
    safe_output_file(asset, description="release package")
    safe_output_file(checksum, description="release package checksum")
    asset.unlink(missing_ok=True)
    checksum.unlink(missing_ok=True)
    root_name = f"cjdoc-{release_version}"
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
    parser.add_argument("--worker-binary", type=Path,
                        help="CHIR worker staged beside --binary; defaults to its sibling")
    parser.add_argument("--platform", required=True,
                        choices=("linux-x64", "windows-x64", "macos-arm64"))
    parser.add_argument("--output", type=Path, default=repo / "target/release-package")
    parser.add_argument("--source-commit", default=os.environ.get("CJDOC_RELEASE_COMMIT"))
    parser.add_argument("--release-tag", default=os.environ.get("CJDOC_RELEASE_TAG"))
    parser.add_argument("--sdk-version", required=True)
    parser.add_argument("--sdk-sha256", required=True)
    parser.add_argument("--stdx-version", required=True)
    parser.add_argument("--stdx-sha256", required=True)
    parser.add_argument("--sdk-root", type=Path,
                        default=Path(configured_sdk_root) if configured_sdk_root else None)
    parser.add_argument("--candidate-receipt", type=Path, required=True,
                        help="cjdoc.release-candidate/2 receipt that accepted these binaries")
    args = parser.parse_args()
    try:
        binary = resolve_binary(args.binary)
        windows = args.platform.startswith("windows-")
        # The worker is expected beside the CLI exactly as it will be installed;
        # an explicit path is only needed for a differently staged build.
        worker = resolve_binary(
            args.worker_binary if args.worker_binary is not None
            else binary.parent / worker_executable(windows))
        if args.source_commit is None:
            raise ValueError("--source-commit or CJDOC_RELEASE_COMMIT is required")
        if not COMMIT.fullmatch(args.source_commit):
            raise ValueError("source commit must be a lowercase 40-hex commit")
        verify_source_commit(repo, args.source_commit)
        version = committed_package_version(repo, args.source_commit)
        if not args.release_tag:
            raise ValueError("--release-version or CJDOC_RELEASE_TAG is required")
        release_version = release_version_from_tag(args.release_tag)
        if release_version.split("-", 1)[0] != version:
            raise ValueError(
                f"release tag {args.release_tag!r} does not match package version v{version}"
            )
        if args.sdk_root is None:
            raise ValueError("--sdk-root or CANGJIE_SDK_ROOT is required")
        if not SHA256.fullmatch(args.sdk_sha256):
            raise ValueError("SDK archive SHA-256 must be lowercase 64-hex")
        if not args.sdk_version:
            raise ValueError("SDK version is missing")
        validate_combined_sdk_root(args.sdk_root, args.sdk_sha256, args.stdx_sha256)
        verify_binary_version(binary, version)
        candidate_receipt = json.loads(Path(args.candidate_receipt).read_text(encoding="utf-8"))
        asset = build_archive(
            repo, binary, args.platform, args.output,
            source_commit=args.source_commit,
            sdk_version=args.sdk_version,
            sdk_sha256=args.sdk_sha256,
            release_version=release_version,
            stdx_version=args.stdx_version,
            stdx_sha256=args.stdx_sha256,
            candidate_receipt=candidate_receipt,
            worker=worker,
        )
        package_evidence = verify_archive(
            asset, args.platform, release_version, args.sdk_version, args.sdk_sha256,
            args.source_commit, smoke=True, repository=repo,
            sdk_root=args.sdk_root, sdk_marker_verified=True,
            stdx_version=args.stdx_version, stdx_sha256=args.stdx_sha256,
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
