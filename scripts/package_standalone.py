#!/usr/bin/env python3
"""Package one verified cjdoc executable as a release asset."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import re
import stat
import tempfile

try:
    from .safe_output_root import lexical_absolute, safe_regular_file, verify_directory_chain
except ImportError:  # Direct script execution.
    from safe_output_root import lexical_absolute, safe_regular_file, verify_directory_chain


SEMVER = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
PLATFORMS = {"linux-x64": "", "macos-arm64": "", "windows-x64": ".exe"}
MAX_BINARY_BYTES = 512 * 1024 * 1024


def hash_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def path_exists_no_follow(path: Path) -> bool:
    try:
        path.lstat()
        return True
    except FileNotFoundError:
        return False


def publish_no_replace(temporary: Path, destination: Path) -> None:
    """Atomically publish one file while refusing every pre-existing destination."""
    try:
        # The source is our same-directory mkstemp regular file. Hard-link
        # publication is atomic and, unlike replace(), never overwrites an
        # existing destination on any supported release platform.
        os.link(temporary, destination)
    except FileExistsError as error:
        raise ValueError(f"standalone release asset already exists: {destination.name}") from error


def package(binary: Path, output: Path, platform: str, version: str) -> tuple[Path, Path]:
    if platform not in PLATFORMS:
        raise ValueError(f"unsupported platform: {platform}")
    if SEMVER.fullmatch(version) is None:
        raise ValueError("version must be semantic version without a v prefix")
    binary = safe_regular_file(binary, description="cjdoc executable")
    metadata = binary.lstat()
    if metadata.st_size < 1 or metadata.st_size > MAX_BINARY_BYTES:
        raise ValueError("cjdoc executable size is outside the release limit")
    output = verify_directory_chain(lexical_absolute(output), create=True)
    name = f"cjdoc-{version}-{platform}{PLATFORMS[platform]}"
    asset = output / name
    checksum = output / f"{name}.sha256"
    if path_exists_no_follow(asset) or path_exists_no_follow(checksum):
        raise ValueError("standalone release asset already exists")
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{name}.", dir=output)
    temporary = Path(temporary_name)
    temporary_checksum: Path | None = None
    try:
        flags = os.O_RDONLY
        if hasattr(os, "O_BINARY"):
            flags |= os.O_BINARY
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        try:
            source_descriptor = os.open(binary, flags)
        except BaseException:
            os.close(descriptor)
            raise
        digest = hashlib.sha256()
        copied = 0
        with os.fdopen(descriptor, "wb") as destination, \
                os.fdopen(source_descriptor, "rb") as source:
            opened = os.fstat(source.fileno())
            if not stat.S_ISREG(opened.st_mode) or \
                    (opened.st_dev, opened.st_ino) != (metadata.st_dev, metadata.st_ino) or \
                    opened.st_size != metadata.st_size:
                raise ValueError("cjdoc executable changed while packaging")
            for block in iter(lambda: source.read(1024 * 1024), b""):
                destination.write(block)
                digest.update(block)
                copied += len(block)
            destination.flush()
            os.fsync(destination.fileno())
            final_source = os.fstat(source.fileno())
            if copied != metadata.st_size or \
                    (final_source.st_dev, final_source.st_ino) != \
                    (metadata.st_dev, metadata.st_ino) or \
                    final_source.st_size != metadata.st_size:
                raise ValueError("cjdoc executable changed while packaging")
        temporary.chmod(0o755)
        before = digest.hexdigest()
        if hash_file(temporary) != before:
            raise ValueError("cjdoc executable changed while packaging")
        checksum_descriptor, checksum_name = tempfile.mkstemp(
            prefix=f".{checksum.name}.", dir=output,
        )
        temporary_checksum = Path(checksum_name)
        with os.fdopen(checksum_descriptor, "w", encoding="ascii", newline="\n") as stream:
            stream.write(f"{before}  {name}\n")
            stream.flush()
            os.fsync(stream.fileno())
        publish_no_replace(temporary, asset)
        publish_no_replace(temporary_checksum, checksum)
    finally:
        # Once published, never unlink by pathname during error cleanup: an
        # adversary could exchange that directory entry between an identity
        # check and unlink. A checksum publication failure therefore leaves
        # our immutable asset in place and fails the job; the exact-set
        # publisher will never accept or upload the incomplete pair.
        temporary.unlink(missing_ok=True)
        if temporary_checksum is not None:
            temporary_checksum.unlink(missing_ok=True)
    return asset, checksum


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--platform", choices=sorted(PLATFORMS), required=True)
    parser.add_argument("--version", required=True)
    args = parser.parse_args()
    asset, checksum = package(args.binary, args.output, args.platform, args.version)
    print(asset)
    print(checksum)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
