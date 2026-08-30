#!/usr/bin/env python3
"""Install one checksum-pinned Cangjie SDK archive for CI."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import tarfile
import tempfile
import urllib.parse
import urllib.request
import zipfile

try:
    from .archive_limits import archive_magic, inspect_tar_headers, inspect_zip_directory
    from .safe_output_root import lexical_absolute
    from .strict_json import strict_load
except ImportError:  # Direct script execution.
    from archive_limits import archive_magic, inspect_tar_headers, inspect_zip_directory
    from safe_output_root import lexical_absolute
    from strict_json import strict_load


CACHE_MARKER = ".cjdoc-sdk-cache.json"
CACHE_ARCHIVE = ".cjdoc-sdk-archive"
CACHE_MARKER_SCHEMA = "cjdoc.sdk-cache/3"
SHA256 = re.compile(r"^[0-9a-f]{64}$")
MAX_ARCHIVE_SIZE = 2 * 1024 * 1024 * 1024
MAX_ARCHIVE_MEMBERS = 100000
MAX_MEMBER_SIZE = 4 * 1024 * 1024 * 1024
MAX_TOTAL_SIZE = 12 * 1024 * 1024 * 1024
MAX_ZIP_DIRECTORY_SIZE = 64 * 1024 * 1024
MAX_TAR_EXTENSION_HEADERS = 2048
MAX_TAR_EXTENSION_SIZE = 64 * 1024 * 1024
MAX_TAR_EXPANDED_SIZE = MAX_TOTAL_SIZE + MAX_TAR_EXTENSION_SIZE + \
    (MAX_ARCHIVE_MEMBERS + MAX_TAR_EXTENSION_HEADERS + 32) * 1024


def sdk_root(directory: Path) -> Path | None:
    candidates: list[Path] = []
    for setup_name in ("envsetup.sh", "envsetup.ps1", "envsetup.bat"):
        for setup in directory.rglob(setup_name):
            candidate = setup.parent
            if (candidate / "bin").is_dir() and candidate not in candidates:
                candidates.append(candidate)
    if not candidates:
        return None
    return min(candidates, key=lambda path: (len(path.relative_to(directory).parts), str(path)))


def archive_name(url: str) -> str:
    parsed = urllib.parse.urlparse(url)
    query_name = urllib.parse.parse_qs(parsed.query).get("fileName", [])
    if query_name:
        return Path(query_name[0]).name
    name = Path(urllib.parse.unquote(parsed.path)).name
    if name:
        return name
    raise ValueError("download URL does not contain an archive filename")


def download(url: str, output: Path) -> None:
    request = urllib.request.Request(url, headers={"User-Agent": "cjdoc-ci/1"})
    with urllib.request.urlopen(request, timeout=120) as response, output.open("wb") as target:
        raw_total = response.headers.get("Content-Length")
        try:
            total = int(raw_total) if raw_total is not None else 0
        except ValueError as error:
            raise ValueError("download response has an invalid Content-Length") from error
        if total < 0 or total > MAX_ARCHIVE_SIZE:
            raise ValueError("SDK archive exceeds the download size limit")
        received = 0
        next_report = 64 * 1024 * 1024
        while block := response.read(1024 * 1024):
            if received + len(block) > MAX_ARCHIVE_SIZE:
                raise ValueError("SDK archive exceeds the download size limit")
            target.write(block)
            received += len(block)
            if received >= next_report:
                if total:
                    print(f"downloaded {received // 1048576}/{total // 1048576} MiB", flush=True)
                else:
                    print(f"downloaded {received // 1048576} MiB", flush=True)
                next_report += 64 * 1024 * 1024
        if total and received != total:
            raise ValueError(
                f"SDK archive download length mismatch: expected {total}, got {received}"
            )


def verify_sha256(archive: Path, expected: str) -> None:
    digest = hashlib.sha256()
    with archive.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    actual = digest.hexdigest()
    if actual.lower() != expected.lower():
        raise ValueError(f"SHA256 mismatch: expected {expected.lower()}, got {actual}")


def tree_sha256(directory: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(directory.rglob("*"), key=lambda item: item.relative_to(directory).as_posix()):
        relative = path.relative_to(directory).as_posix()
        if relative in (CACHE_MARKER, CACHE_ARCHIVE):
            continue
        metadata = path.lstat()
        if stat.S_ISLNK(metadata.st_mode):
            kind = b"L"
            content = os.readlink(path).encode("utf-8")
        elif stat.S_ISREG(metadata.st_mode):
            kind = b"F"
            content = None
        elif stat.S_ISDIR(metadata.st_mode):
            kind = b"D"
            content = b""
        else:
            raise ValueError(f"SDK cache contains an unsupported filesystem entry: {relative}")
        digest.update(kind)
        digest.update(b"\0")
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        # Authenticate the portable permission/special-bit portion only; file
        # type is encoded separately above and platform-specific stat bits are
        # deliberately excluded.
        digest.update(f"{stat.S_IMODE(metadata.st_mode):04o}".encode("ascii"))
        digest.update(b"\0")
        if content is not None:
            digest.update(content)
        else:
            with path.open("rb") as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(block)
        digest.update(b"\0")
    return digest.hexdigest()


def safe_marker_root(destination: Path, value: object) -> Path:
    if not isinstance(value, str) or not value or "\\" in value:
        raise ValueError("SDK cache marker root must be a safe POSIX relative path")
    relative = PurePosixPath(value)
    if value == ".." or relative.as_posix() != value or relative.is_absolute() or \
            any(part in ("", "..") for part in relative.parts):
        raise ValueError("SDK cache marker root is unsafe")
    root = destination.joinpath(*relative.parts).resolve()
    if os.path.commonpath((destination.resolve(), root)) != str(destination.resolve()):
        raise ValueError("SDK cache marker root escapes the destination")
    return root


def marker_value(destination: Path, root: Path, archive_filename: str,
                 archive_sha256: str) -> dict[str, object]:
    return {
        "schemaVersion": CACHE_MARKER_SCHEMA,
        "archiveName": archive_filename,
        "archiveSha256": archive_sha256,
        "sdkRoot": root.relative_to(destination).as_posix(),
        "treeSha256": tree_sha256(destination),
    }


def write_cache_marker(destination: Path, root: Path, archive_filename: str,
                       archive_sha256: str) -> None:
    cached_archive = destination / CACHE_ARCHIVE
    verify_archive_file(cached_archive)
    verify_sha256(cached_archive, archive_sha256)
    value = marker_value(destination, root, archive_filename, archive_sha256)
    marker = destination / CACHE_MARKER
    with tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", dir=destination, prefix=f".{CACHE_MARKER}.", delete=False
    ) as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2, sort_keys=True)
        stream.write("\n")
        temporary = Path(stream.name)
    os.replace(temporary, marker)


def validate_cached_sdk(destination: Path, archive_filename: str,
                        archive_sha256: str) -> Path:
    if destination.is_symlink() or not destination.is_dir():
        raise ValueError("SDK cache destination must be a regular directory")
    marker_path = destination / CACHE_MARKER
    if marker_path.is_symlink() or not marker_path.is_file():
        raise ValueError(f"existing SDK cache has no verified extraction marker: {destination}")
    try:
        marker = strict_load(marker_path, description="SDK cache marker")
    except ValueError as error:
        raise ValueError(f"SDK cache marker is invalid: {error}") from error
    expected_keys = {
        "schemaVersion", "archiveName", "archiveSha256", "sdkRoot", "treeSha256"
    }
    if not isinstance(marker, dict) or set(marker) != expected_keys or \
            marker.get("schemaVersion") != CACHE_MARKER_SCHEMA:
        raise ValueError("SDK cache marker schema is unknown")
    marker_archive_name = marker.get("archiveName")
    if not isinstance(marker_archive_name, str) or not marker_archive_name or \
            marker_archive_name in (".", "..") or "/" in marker_archive_name or \
            "\\" in marker_archive_name or "\x00" in marker_archive_name:
        raise ValueError("SDK cache marker archive name is invalid")
    if marker.get("archiveSha256") != archive_sha256:
        raise ValueError("SDK cache marker does not match the requested archive")
    cached_archive = destination / CACHE_ARCHIVE
    if cached_archive.is_symlink() or not cached_archive.is_file():
        raise ValueError("SDK cache omits its checksum-pinned archive")
    verify_archive_file(cached_archive)
    verify_sha256(cached_archive, archive_sha256)
    expected_tree = marker.get("treeSha256")
    if not isinstance(expected_tree, str) or not SHA256.fullmatch(expected_tree):
        raise ValueError("SDK cache marker tree digest is invalid")
    root = safe_marker_root(destination, marker.get("sdkRoot"))
    if not root.is_dir() or sdk_root(root) != root:
        raise ValueError("SDK cache marker does not identify a complete SDK root")
    actual_tree = tree_sha256(destination)
    if actual_tree != expected_tree:
        raise ValueError("SDK cache tree digest does not match the verified extraction marker")
    with tempfile.TemporaryDirectory(
        prefix="cjdoc-sdk-authenticate-", dir=destination.parent
    ) as temporary:
        authenticated = Path(temporary) / "extracted"
        authenticated.mkdir()
        extract(cached_archive, authenticated)
        if any((authenticated / name).exists() or (authenticated / name).is_symlink()
               for name in (CACHE_MARKER, CACHE_ARCHIVE)):
            raise ValueError("cached SDK archive uses a reserved cache metadata path")
        authenticated_root = sdk_root(authenticated)
        if authenticated_root is None:
            raise ValueError("cached SDK archive does not contain a Cangjie SDK root")
        if authenticated_root.relative_to(authenticated).as_posix() != marker.get("sdkRoot"):
            raise ValueError("SDK cache root does not match the authenticated archive extraction")
        if tree_sha256(authenticated) != expected_tree:
            raise ValueError("SDK cache tree does not match the authenticated archive extraction")
    return root


def validate_cached_sdk_root(root: Path, archive_sha256: str) -> Path:
    root = lexical_absolute(root)
    if root.is_symlink() or not root.is_dir() or root.resolve(strict=True) != root:
        raise ValueError("active SDK root must be a canonical regular directory")
    candidates = (root, *root.parents)
    for destination in candidates:
        marker_path = destination / CACHE_MARKER
        try:
            marker_metadata = marker_path.lstat()
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(marker_metadata.st_mode):
            raise ValueError("SDK cache marker must not be a symlink")
        if not stat.S_ISREG(marker_metadata.st_mode):
            raise ValueError("SDK cache marker must be a regular file")
        try:
            marker = strict_load(marker_path, description="SDK cache marker")
        except ValueError as error:
            raise ValueError(f"SDK cache marker is invalid: {error}") from error
        archive_filename = marker.get("archiveName") if isinstance(marker, dict) else None
        if not isinstance(archive_filename, str) or not archive_filename:
            raise ValueError("SDK cache marker archive name is invalid")
        validated = validate_cached_sdk(destination, archive_filename, archive_sha256)
        if validated.resolve() != root:
            raise ValueError("active SDK root does not match its verified extraction marker")
        return validated
    raise ValueError("active SDK root has no verified extraction marker")


def ensure_inside(root: Path, member_name: str) -> None:
    target = (root / member_name).resolve()
    if os.path.commonpath((root.resolve(), target)) != str(root.resolve()):
        raise ValueError(f"archive member escapes destination: {member_name}")


def safe_member_name(value: str, *, directory: bool = False) -> str:
    candidate = value[:-1] if directory and value.endswith("/") else value
    if not candidate or "\\" in candidate or "\x00" in candidate:
        raise ValueError(f"unsafe SDK archive member path: {value!r}")
    relative = PurePosixPath(candidate)
    if relative.is_absolute() or relative.as_posix() != candidate or \
            any(part in ("", ".", "..") for part in relative.parts):
        raise ValueError(f"unsafe SDK archive member path: {value!r}")
    return relative.as_posix()


def checked_member_size(name: str, size: int, total: int) -> int:
    if size < 0 or size > MAX_MEMBER_SIZE:
        raise ValueError(f"SDK archive member is too large: {name}")
    total += size
    if total > MAX_TOTAL_SIZE:
        raise ValueError("SDK archive expanded payload exceeds the size limit")
    return total


def verify_archive_file(archive: Path) -> None:
    metadata = archive.lstat()
    if archive.is_symlink() or not stat.S_ISREG(metadata.st_mode):
        raise ValueError("SDK archive must be a regular file")
    if metadata.st_size < 1 or metadata.st_size > MAX_ARCHIVE_SIZE:
        raise ValueError("SDK archive exceeds the download size limit")


def verify_zip_members(archive: Path, destination: Path) -> None:
    inspect_zip_directory(
        archive, max_entries=MAX_ARCHIVE_MEMBERS,
        max_directory_size=MAX_ZIP_DIRECTORY_SIZE,
    )
    total = 0
    names: set[str] = set()
    with zipfile.ZipFile(archive) as package:
        for member in package.infolist():
            is_directory = member.is_dir()
            normalized = safe_member_name(member.filename, directory=is_directory)
            if normalized in names:
                raise ValueError(f"duplicate SDK archive member: {normalized}")
            names.add(normalized)
            ensure_inside(destination, normalized)
            mode = (member.external_attr >> 16) & 0xFFFF
            file_type = stat.S_IFMT(mode)
            expected_types = (0, stat.S_IFDIR) if is_directory else (0, stat.S_IFREG)
            if file_type not in expected_types:
                raise ValueError(f"unsupported SDK ZIP member type: {normalized}")
            if member.flag_bits & 0x1:
                raise ValueError(f"encrypted SDK ZIP member is unsupported: {normalized}")
            total = checked_member_size(
                normalized, 0 if is_directory else member.file_size, total
            )


def verify_tar_members(archive: Path, destination: Path, *, compressed: bool) -> None:
    inspect_tar_headers(
        archive, compressed=compressed,
        max_headers=MAX_ARCHIVE_MEMBERS + MAX_TAR_EXTENSION_HEADERS,
        max_member_size=MAX_MEMBER_SIZE, max_total_size=MAX_TOTAL_SIZE,
        max_expanded_size=MAX_TAR_EXPANDED_SIZE,
        max_extension_headers=MAX_TAR_EXTENSION_HEADERS,
        max_extension_size=MAX_TAR_EXTENSION_SIZE, allow_extensions=True,
        allowed_member_types=frozenset((b"\0", b"0", b"1", b"2", b"5")),
    )
    total = 0
    names: set[str] = set()
    mode = "r:gz" if compressed else "r:"
    with tarfile.open(archive, mode=mode) as package:
        for index, member in enumerate(package):
            if index >= MAX_ARCHIVE_MEMBERS:
                raise ValueError("SDK archive contains too many members")
            normalized = safe_member_name(member.name, directory=member.isdir())
            if normalized in names:
                raise ValueError(f"duplicate SDK archive member: {normalized}")
            names.add(normalized)
            if member.type not in (
                tarfile.AREGTYPE, tarfile.REGTYPE, tarfile.LNKTYPE,
                tarfile.SYMTYPE, tarfile.DIRTYPE,
            ):
                raise ValueError(f"unsupported SDK tar member type: {normalized}")
            try:
                tarfile.data_filter(member, destination)
            except tarfile.TarError as error:
                raise ValueError(f"unsafe SDK tar member: {normalized}: {error}") from error
            total = checked_member_size(
                normalized, member.size if member.isfile() else 0, total
            )


def extract(archive: Path, destination: Path) -> None:
    verify_archive_file(archive)
    archive_type = archive_magic(archive)
    if archive_type == "zip":
        verify_zip_members(archive, destination)
        with zipfile.ZipFile(archive) as package:
            package.extractall(destination)
        return
    if archive_type in ("tar", "gzip-tar"):
        compressed = archive_type == "gzip-tar"
        verify_tar_members(archive, destination, compressed=compressed)
        with tarfile.open(archive, mode="r:gz" if compressed else "r:") as package:
            package.extractall(destination, filter="data")
        return
    raise ValueError(f"unsupported SDK archive: {archive.name}")


def write_github_output(output: Path | None, root: Path) -> None:
    normalized = root.resolve().as_posix()
    if "\n" in normalized or "\r" in normalized:
        raise ValueError("Cangjie SDK root contains a line break")
    print(f"Cangjie SDK root: {normalized}")
    if output is not None:
        with output.open("a", encoding="utf-8", newline="\n") as stream:
            stream.write(f"root={normalized}\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True)
    parser.add_argument("--sha256", required=True)
    parser.add_argument("--destination", required=True, type=Path)
    parser.add_argument("--github-output", type=Path)
    args = parser.parse_args()

    if not SHA256.fullmatch(args.sha256):
        raise ValueError("--sha256 must be lowercase 64-hex")

    destination = lexical_absolute(args.destination)
    if destination.is_symlink():
        raise ValueError("SDK cache destination must not be a symlink")
    filename = archive_name(args.url)
    if destination.is_dir():
        root = validate_cached_sdk(destination, filename, args.sha256)
        write_github_output(args.github_output, root)
        return 0
    if destination.exists():
        raise ValueError(f"existing SDK cache is incomplete: {destination}")

    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="cjdoc-sdk-", dir=destination.parent) as temporary:
        temporary_path = Path(temporary)
        archive = temporary_path / filename
        extracted = temporary_path / "extracted"
        extracted.mkdir()
        download(args.url, archive)
        verify_sha256(archive, args.sha256)
        extract(archive, extracted)
        if any((extracted / name).exists() or (extracted / name).is_symlink()
               for name in (CACHE_MARKER, CACHE_ARCHIVE)):
            raise ValueError("SDK archive uses a reserved cache metadata path")
        extracted_root = sdk_root(extracted)
        if extracted_root is None:
            raise ValueError("archive does not contain a Cangjie SDK root")
        shutil.copyfile(archive, extracted / CACHE_ARCHIVE)
        write_cache_marker(extracted, extracted_root, filename, args.sha256)
        shutil.move(str(extracted), destination)

    root = validate_cached_sdk(destination, filename, args.sha256)
    write_github_output(args.github_output, root)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
