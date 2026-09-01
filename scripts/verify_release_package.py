#!/usr/bin/env python3
"""Inspect and safely smoke-test one cjdoc release archive."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import tarfile
import tempfile
import zipfile

try:
    from .archive_limits import archive_magic, inspect_tar_headers, inspect_zip_directory
    from .install_cangjie_sdk import validate_cached_sdk_root
    from .safe_output_root import lexical_absolute, safe_regular_file, verify_directory_chain
    from .strict_json import strict_loads
except ImportError:  # Direct script execution.
    from archive_limits import archive_magic, inspect_tar_headers, inspect_zip_directory
    from install_cangjie_sdk import validate_cached_sdk_root
    from safe_output_root import lexical_absolute, safe_regular_file, verify_directory_chain
    from strict_json import strict_loads


COMMIT = re.compile(r"^[0-9a-f]{40}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
SEMVER = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
MAX_MEMBERS = 128
MAX_ARCHIVE_SIZE = 512 * 1024 * 1024
MAX_MEMBER_SIZE = 512 * 1024 * 1024
MAX_TOTAL_SIZE = 1024 * 1024 * 1024
MAX_ZIP_DIRECTORY_SIZE = 8 * 1024 * 1024
MAX_TAR_EXPANDED_SIZE = MAX_TOTAL_SIZE + (MAX_MEMBERS + 32) * 1024
MAX_MANIFEST_SIZE = 1024 * 1024
STREAM_CHUNK_SIZE = 1024 * 1024
SCHEMA_PAYLOAD = {
    "docs/schema/doc-ir.schema.json",
    "docs/schema/doc-ir-v6.schema.json",
    "docs/schema/doc-ir-v7.schema.json",
    "docs/schema/doc-ir-v8.schema.json",
    "docs/schema/diagnostics.schema.json",
    "docs/schema/cfg-matrix.schema.json",
    "docs/schema/search-index.schema.json",
    "docs/schema/api-surface.schema.json",
    "docs/schema/documentation-coverage.schema.json",
}
REPOSITORY_PAYLOAD = {
    "README.md": "README.md",
    "LICENSE": "LICENSE",
    "THIRD_PARTY_NOTICES.md": "THIRD_PARTY_NOTICES.md",
    "licenses/markdown-MIT.txt": "third_party/licenses/markdown-LICENSE",
    "licenses/yjson-Apache-2.0.txt": "vendor/yjson_algorithms/LICENSE",
    **{name: name for name in SCHEMA_PAYLOAD},
}


@dataclass(frozen=True)
class ArchiveMember:
    name: str
    size: int
    sha256: str
    mode: int
    content: bytes | None = None


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    path = lexical_absolute(path)
    try:
        safe_regular_file(path, description="release archive")
    except ValueError as error:
        raise ValueError(f"release archive is not a regular file: {path.name}") from error
    before = path.lstat()
    if not stat.S_ISREG(before.st_mode):
        raise ValueError(f"release archive is not a regular file: {path.name}")
    if before.st_size < 1 or before.st_size > MAX_ARCHIVE_SIZE:
        raise ValueError(f"release archive size exceeds the verification limit: {path.name}")
    digest = hashlib.sha256()
    flags = os.O_RDONLY
    if hasattr(os, "O_BINARY"):
        flags |= os.O_BINARY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags)
    try:
        opened = os.fstat(descriptor)
        if not stat.S_ISREG(opened.st_mode) or (opened.st_dev, opened.st_ino) != \
                (before.st_dev, before.st_ino) or opened.st_size != before.st_size:
            raise ValueError("release archive changed while hashing")
        while True:
            block = os.read(descriptor, STREAM_CHUNK_SIZE)
            if not block:
                break
            digest.update(block)
        after = os.fstat(descriptor)
        if (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns) != \
                (opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns):
            raise ValueError("release archive changed while hashing")
    finally:
        os.close(descriptor)
    return digest.hexdigest()


def safe_member_name(value: str) -> PurePosixPath:
    if not value or "\\" in value or "\x00" in value:
        raise ValueError(f"unsafe archive member path: {value!r}")
    path = PurePosixPath(value)
    if value in (".", "..") or path.as_posix() != value or path.is_absolute() or \
            any(part in ("", ".", "..") for part in path.parts):
        raise ValueError(f"unsafe archive member path: {value!r}")
    return path


def checked_size(name: str, size: int, total: int) -> int:
    if size < 0 or size > MAX_MEMBER_SIZE:
        raise ValueError(f"archive member is too large: {name}")
    total += size
    if total > MAX_TOTAL_SIZE:
        raise ValueError("archive payload exceeds the verification limit")
    return total


def read_member_stream(stream, *, name: str, expected_size: int,
                       capture: bool = False, output=None) -> tuple[str, bytes | None]:
    """Hash one bounded member without retaining ordinary payload bytes."""
    digest = hashlib.sha256()
    captured = bytearray() if capture else None
    observed = 0
    while True:
        block = stream.read(STREAM_CHUNK_SIZE)
        if not block:
            break
        observed += len(block)
        if observed > expected_size:
            raise ValueError(f"release archive member exceeds its declared size: {name}")
        digest.update(block)
        if captured is not None:
            captured.extend(block)
        if output is not None:
            output.write(block)
    if observed != expected_size:
        raise ValueError(f"release archive member size changed while reading: {name}")
    return digest.hexdigest(), bytes(captured) if captured is not None else None


def is_manifest_candidate(name: str) -> bool:
    parts = PurePosixPath(name).parts
    return len(parts) == 2 and parts[1] == "release-manifest.json"


def read_zip(path: Path) -> dict[str, ArchiveMember]:
    members: dict[str, ArchiveMember] = {}
    total = 0
    manifest_seen = False
    inspect_zip_directory(
        path, max_entries=MAX_MEMBERS, max_directory_size=MAX_ZIP_DIRECTORY_SIZE
    )
    with zipfile.ZipFile(path) as archive:
        infos = archive.infolist()
        if len(infos) > MAX_MEMBERS:
            raise ValueError("release archive contains too many members")
        for info in infos:
            normalized = safe_member_name(info.filename).as_posix()
            if info.is_dir():
                raise ValueError(f"release archive contains an unexpected directory member: {normalized}")
            mode = (info.external_attr >> 16) & 0xFFFF
            file_type = stat.S_IFMT(mode)
            if file_type not in (0, stat.S_IFREG):
                raise ValueError(f"release archive contains a non-file member: {normalized}")
            if info.flag_bits & 0x1:
                raise ValueError(f"release archive contains an encrypted member: {normalized}")
            if normalized in members:
                raise ValueError(f"release archive contains a duplicate member: {normalized}")
            total = checked_size(normalized, info.file_size, total)
            capture = is_manifest_candidate(normalized)
            if capture:
                if manifest_seen:
                    raise ValueError("release archive contains multiple manifest candidates")
                if info.file_size > MAX_MANIFEST_SIZE:
                    raise ValueError("release manifest exceeds the verification limit")
                manifest_seen = True
            with archive.open(info, "r") as stream:
                digest, content = read_member_stream(
                    stream, name=normalized, expected_size=info.file_size,
                    capture=capture,
                )
            members[normalized] = ArchiveMember(
                normalized, info.file_size, digest, mode & 0o7777, content
            )
    return members


def read_tar(path: Path, *, compressed: bool) -> dict[str, ArchiveMember]:
    members: dict[str, ArchiveMember] = {}
    total = 0
    manifest_seen = False
    inspect_tar_headers(
        path, compressed=compressed, max_headers=MAX_MEMBERS,
        max_member_size=MAX_MEMBER_SIZE, max_total_size=MAX_TOTAL_SIZE,
        max_expanded_size=MAX_TAR_EXPANDED_SIZE,
        max_extension_headers=0, max_extension_size=0, allow_extensions=False,
        allowed_member_types=frozenset((b"\0", b"0")),
    )
    with tarfile.open(path, mode="r:gz" if compressed else "r:") as archive:
        for index, info in enumerate(archive):
            if index >= MAX_MEMBERS:
                raise ValueError("release archive contains too many members")
            normalized = safe_member_name(info.name).as_posix()
            if not info.isfile():
                raise ValueError(f"release archive contains a non-file member: {normalized}")
            if normalized in members:
                raise ValueError(f"release archive contains a duplicate member: {normalized}")
            total = checked_size(normalized, info.size, total)
            stream = archive.extractfile(info)
            if stream is None:
                raise ValueError(f"release archive member cannot be read: {normalized}")
            capture = is_manifest_candidate(normalized)
            if capture:
                if manifest_seen:
                    raise ValueError("release archive contains multiple manifest candidates")
                if info.size > MAX_MANIFEST_SIZE:
                    raise ValueError("release manifest exceeds the verification limit")
                manifest_seen = True
            with stream:
                digest, content = read_member_stream(
                    stream, name=normalized, expected_size=info.size,
                    capture=capture,
                )
            members[normalized] = ArchiveMember(
                normalized, info.size, digest, info.mode & 0o7777, content
            )
    return members


def read_archive(path: Path, *, expected_format: str | None = None) -> dict[str, ArchiveMember]:
    path = lexical_absolute(path)
    try:
        safe_regular_file(path, description="release archive")
    except ValueError as error:
        raise ValueError(f"release archive is not a regular file: {path.name}") from error
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode):
        raise ValueError(f"release archive is not a regular file: {path.name}")
    archive_size = metadata.st_size
    if archive_size < 1 or archive_size > MAX_ARCHIVE_SIZE:
        raise ValueError(f"release archive size exceeds the verification limit: {path.name}")
    actual_format = archive_magic(path)
    if expected_format is not None and actual_format != expected_format:
        raise ValueError(
            f"release archive format mismatch: expected {expected_format}, got {actual_format}"
        )
    if actual_format == "zip":
        return read_zip(path)
    if actual_format in ("tar", "gzip-tar"):
        return read_tar(path, compressed=actual_format == "gzip-tar")
    raise ValueError(f"unsupported release archive: {path.name}")


def committed_file(repo: Path, source_commit: str, relative: str) -> bytes:
    tree = subprocess.run(
        ["git", "-C", str(repo), "ls-tree", "-z", source_commit, "--", relative],
        capture_output=True, check=False,
    )
    entry = tree.stdout.rstrip(b"\0")
    if tree.returncode != 0 or not entry or b"\0" in entry:
        raise ValueError(f"release source commit omits package payload: {relative}")
    metadata, separator, name = entry.partition(b"\t")
    fields = metadata.split()
    if separator != b"\t" or name.decode("utf-8", "strict") != relative or \
            len(fields) != 3 or fields[0] not in (b"100644", b"100755") or fields[1] != b"blob":
        raise ValueError(f"release source payload is not a regular committed file: {relative}")
    result = subprocess.run(
        ["git", "-C", str(repo), "show", f"{source_commit}:{relative}"],
        capture_output=True, check=False,
    )
    if result.returncode != 0:
        raise ValueError(f"cannot read release source payload: {relative}")
    return result.stdout


def verify_repository_payload(members: dict[str, ArchiveMember], repo: Path,
                              source_commit: str) -> None:
    repo = lexical_absolute(repo)
    try:
        verify_directory_chain(repo)
    except ValueError as error:
        raise ValueError("release repository must be a canonical regular directory") from error
    if not repo.is_dir():
        raise ValueError("release repository must be a canonical regular directory")
    for archive_name, repository_name in REPOSITORY_PAYLOAD.items():
        member = members.get(archive_name)
        if member is None:
            raise ValueError(f"release package omits repository payload: {archive_name}")
        expected = committed_file(repo, source_commit, repository_name)
        if member.size != len(expected) or member.sha256 != sha256_bytes(expected):
            raise ValueError(
                f"release package payload does not match source commit: {archive_name}"
            )


def inspect_archive(path: Path, platform_name: str, version: str,
                    sdk_version: str, sdk_sha256: str,
                    source_commit: str) -> tuple[dict[str, object], dict[str, ArchiveMember], str]:
    path = lexical_absolute(path)
    if not SEMVER.fullmatch(version):
        raise ValueError("release package version must be a stable three-part SemVer")
    if not SHA256.fullmatch(sdk_sha256):
        raise ValueError("SDK archive SHA-256 must be lowercase 64-hex")
    if not COMMIT.fullmatch(source_commit):
        raise ValueError("source commit must be lowercase 40-hex")
    extension = ".zip" if platform_name.startswith("windows-") else ".tar.gz"
    expected_archive = f"cjdoc-{version}-{platform_name}{extension}"
    if path.name != expected_archive:
        raise ValueError(f"release archive name must be {expected_archive}")
    expected_format = "zip" if platform_name.startswith("windows-") else "gzip-tar"
    members = read_archive(path, expected_format=expected_format)
    if not members:
        raise ValueError("release archive is empty")
    expected_root = f"cjdoc-{version}"
    roots = {PurePosixPath(name).parts[0] for name in members}
    if roots != {expected_root}:
        raise ValueError(f"release archive root mismatch: {sorted(roots)}")
    relative_members = {
        PurePosixPath(name).relative_to(expected_root).as_posix(): member
        for name, member in members.items()
    }
    manifest_member = relative_members.get("release-manifest.json")
    if manifest_member is None:
        raise ValueError("release archive omits release-manifest.json")
    if manifest_member.content is None:
        raise ValueError("release manifest was not captured during bounded inspection")
    try:
        manifest = strict_loads(
            manifest_member.content, description="release manifest"
        )
    except ValueError as error:
        raise ValueError(f"release manifest is invalid: {error}") from error
    if not isinstance(manifest, dict) or set(manifest) != {
        "schemaVersion", "version", "platform", "sourceCommit", "runtime", "files"
    } or manifest.get("schemaVersion") != "cjdoc.release-package/2":
        raise ValueError("unknown release package manifest schema")
    if manifest.get("version") != version or manifest.get("platform") != platform_name:
        raise ValueError("release package identity does not match its declared target")
    if manifest.get("sourceCommit") != source_commit:
        raise ValueError("release package source commit does not match")
    runtime = manifest.get("runtime")
    if not isinstance(runtime, dict) or set(runtime) != {
        "requiresCangjieSdk", "sdkVersion", "sdkArchiveSha256"
    } or runtime.get("requiresCangjieSdk") is not True or \
            runtime.get("sdkVersion") != sdk_version or runtime.get("sdkArchiveSha256") != sdk_sha256:
        raise ValueError("release package SDK requirement does not match")
    files = manifest.get("files")
    if not isinstance(files, dict):
        raise ValueError("release package manifest files must be an object")
    actual_payload = set(relative_members) - {"release-manifest.json"}
    if set(files) != actual_payload:
        raise ValueError(
            "release package member set mismatch: missing=" +
            ",".join(sorted(set(files) - actual_payload)) +
            " unexpected=" + ",".join(sorted(actual_payload - set(files)))
        )
    for name, metadata in files.items():
        if not isinstance(metadata, dict) or set(metadata) != {"sha256", "size"} or \
                not isinstance(metadata.get("sha256"), str) or \
                not SHA256.fullmatch(metadata["sha256"]) or \
                type(metadata.get("size")) is not int or metadata["size"] < 0:
            raise ValueError(f"invalid release manifest metadata: {name}")
        member = relative_members[name]
        if metadata.get("size") != member.size or \
                metadata.get("sha256") != member.sha256:
            raise ValueError(f"release package payload hash/size mismatch: {name}")
    executable_name = "cjdoc.exe" if platform_name.startswith("windows-") else "cjdoc"
    expected_payload = {
        executable_name,
        "README.md",
        "LICENSE",
        "THIRD_PARTY_NOTICES.md",
        "licenses/markdown-MIT.txt",
        "licenses/yjson-Apache-2.0.txt",
    } | SCHEMA_PAYLOAD
    if actual_payload != expected_payload:
        raise ValueError(
            "release package payload set mismatch: missing=" +
            ",".join(sorted(expected_payload - actual_payload)) +
            " unexpected=" + ",".join(sorted(actual_payload - expected_payload))
        )
    expected_modes = {
        name: (0o755 if name == executable_name else 0o644)
        for name in relative_members
    }
    for name, member in relative_members.items():
        expected_mode = expected_modes[name]
        if member.mode != expected_mode:
            raise ValueError(
                f"release package member mode mismatch: {name} "
                f"must be {expected_mode:04o}, got {member.mode:04o}"
            )
    return manifest, relative_members, executable_name


def prepare_extraction_target(root: Path, relative: str) -> Path:
    """Create private parent directories and return a new regular-file path."""
    parts = safe_member_name(relative).parts
    current = root
    for part in parts[:-1]:
        current = current / part
        try:
            metadata = current.lstat()
        except FileNotFoundError:
            current.mkdir(mode=0o700)
            metadata = current.lstat()
        if current.is_symlink() or not stat.S_ISDIR(metadata.st_mode):
            raise ValueError(f"release extraction path is not a safe directory: {relative}")
    target = current / parts[-1]
    try:
        target.lstat()
    except FileNotFoundError:
        return target
    raise ValueError(f"release extraction target already exists: {relative}")


def write_extracted_member(root: Path, relative: str, member: ArchiveMember,
                           stream) -> None:
    target = prepare_extraction_target(root, relative)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(target, flags, 0o600)
    try:
        with os.fdopen(descriptor, "wb") as output:
            descriptor = -1
            digest, _ = read_member_stream(
                stream, name=member.name, expected_size=member.size, output=output
            )
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    if digest != member.sha256:
        target.unlink(missing_ok=True)
        raise ValueError(f"release archive member changed during extraction: {relative}")
    target.chmod(member.mode)


def extract_members(path: Path, expected_format: str, destination: Path,
                    root_name: str, members: dict[str, ArchiveMember]) -> Path:
    """Reopen and stream verified members into a private smoke-test directory."""
    root = destination / root_name
    root.mkdir(mode=0o700)
    expected = {f"{root_name}/{relative}": (relative, member)
                for relative, member in members.items()}
    observed: set[str] = set()
    actual_format = archive_magic(path)
    if actual_format != expected_format:
        raise ValueError("release archive format changed before extraction")
    if actual_format == "zip":
        with zipfile.ZipFile(path) as archive:
            for info in archive.infolist():
                normalized = safe_member_name(info.filename).as_posix()
                if normalized not in expected or normalized in observed:
                    raise ValueError("release archive members changed before extraction")
                relative, member = expected[normalized]
                mode = ((info.external_attr >> 16) & 0xFFFF) & 0o7777
                if info.file_size != member.size or mode != member.mode:
                    raise ValueError(f"release archive metadata changed before extraction: {relative}")
                with archive.open(info, "r") as stream:
                    write_extracted_member(root, relative, member, stream)
                observed.add(normalized)
    elif actual_format in ("tar", "gzip-tar"):
        mode = "r:gz" if actual_format == "gzip-tar" else "r:"
        with tarfile.open(path, mode=mode) as archive:
            for info in archive:
                normalized = safe_member_name(info.name).as_posix()
                if normalized not in expected or normalized in observed or not info.isfile():
                    raise ValueError("release archive members changed before extraction")
                relative, member = expected[normalized]
                if info.size != member.size or (info.mode & 0o7777) != member.mode:
                    raise ValueError(f"release archive metadata changed before extraction: {relative}")
                stream = archive.extractfile(info)
                if stream is None:
                    raise ValueError(f"release archive member cannot be read: {relative}")
                with stream:
                    write_extracted_member(root, relative, member, stream)
                observed.add(normalized)
    else:
        raise ValueError("unsupported release archive format during extraction")
    if observed != set(expected):
        raise ValueError("release archive members changed before extraction")
    return root


def _inside(root: Path, candidate: Path) -> bool:
    try:
        return os.path.commonpath((str(root), str(candidate))) == str(root)
    except ValueError:
        return False


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
