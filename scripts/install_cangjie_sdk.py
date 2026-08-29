#!/usr/bin/env python3
"""Install one checksum-pinned Cangjie SDK archive for CI."""

from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import tarfile
import tempfile
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path


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
        total = int(response.headers.get("Content-Length", "0"))
        received = 0
        next_report = 64 * 1024 * 1024
        while block := response.read(1024 * 1024):
            target.write(block)
            received += len(block)
            if received >= next_report:
                if total:
                    print(f"downloaded {received // 1048576}/{total // 1048576} MiB", flush=True)
                else:
                    print(f"downloaded {received // 1048576} MiB", flush=True)
                next_report += 64 * 1024 * 1024


def verify_sha256(archive: Path, expected: str) -> None:
    digest = hashlib.sha256()
    with archive.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    actual = digest.hexdigest()
    if actual.lower() != expected.lower():
        raise ValueError(f"SHA256 mismatch: expected {expected.lower()}, got {actual}")


def ensure_inside(root: Path, member_name: str) -> None:
    target = (root / member_name).resolve()
    if os.path.commonpath((root.resolve(), target)) != str(root.resolve()):
        raise ValueError(f"archive member escapes destination: {member_name}")


def extract(archive: Path, destination: Path) -> None:
    if zipfile.is_zipfile(archive):
        with zipfile.ZipFile(archive) as package:
            for member in package.infolist():
                ensure_inside(destination, member.filename)
            package.extractall(destination)
        return
    if tarfile.is_tarfile(archive):
        with tarfile.open(archive) as package:
            package.extractall(destination, filter="data")
        return
    raise ValueError(f"unsupported SDK archive: {archive.name}")


def write_github_output(output: Path | None, root: Path) -> None:
    normalized = root.resolve().as_posix()
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

    destination = args.destination.resolve()
    if destination.is_dir() and (root := sdk_root(destination)) is not None:
        write_github_output(args.github_output, root)
        return 0
    if destination.exists():
        raise ValueError(f"existing SDK cache is incomplete: {destination}")

    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="cjdoc-sdk-", dir=destination.parent) as temporary:
        temporary_path = Path(temporary)
        archive = temporary_path / archive_name(args.url)
        extracted = temporary_path / "extracted"
        extracted.mkdir()
        download(args.url, archive)
        verify_sha256(archive, args.sha256)
        extract(archive, extracted)
        if sdk_root(extracted) is None:
            raise ValueError("archive does not contain a Cangjie SDK root")
        shutil.move(str(extracted), destination)

    root = sdk_root(destination)
    if root is None:
        raise ValueError("installed archive does not contain a Cangjie SDK root")
    write_github_output(args.github_output, root)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
