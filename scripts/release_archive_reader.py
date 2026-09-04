from __future__ import annotations

from dataclasses import dataclass
import hashlib
import os
from pathlib import Path, PurePosixPath
import stat
import tarfile
import zipfile

try:
    from .archive_limits import archive_magic, inspect_tar_headers, inspect_zip_directory
    from .release_package_contracts import (
        MAX_ARCHIVE_SIZE,
        MAX_MANIFEST_SIZE,
        MAX_MEMBERS,
        MAX_MEMBER_SIZE,
        MAX_TAR_EXPANDED_SIZE,
        MAX_TOTAL_SIZE,
        MAX_ZIP_DIRECTORY_SIZE,
        STREAM_CHUNK_SIZE,
    )
    from .safe_output_root import lexical_absolute, safe_regular_file
except ImportError:  # Direct module execution.
    from archive_limits import archive_magic, inspect_tar_headers, inspect_zip_directory
    from release_package_contracts import (
        MAX_ARCHIVE_SIZE,
        MAX_MANIFEST_SIZE,
        MAX_MEMBERS,
        MAX_MEMBER_SIZE,
        MAX_TAR_EXPANDED_SIZE,
        MAX_TOTAL_SIZE,
        MAX_ZIP_DIRECTORY_SIZE,
        STREAM_CHUNK_SIZE,
    )
    from safe_output_root import lexical_absolute, safe_regular_file

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


