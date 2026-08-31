#!/usr/bin/env python3
"""Initialize and verify output directories below the canonical repository target/."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import stat
import sys


_DARWIN_SYSTEM_ALIASES = {
    Path("/var"): Path("/private/var"),
    Path("/tmp"): Path("/private/tmp"),
}


def _is_link_like(path: Path, metadata: os.stat_result) -> bool:
    """Reject symlinks and Windows junctions without resolving the path."""
    is_junction = getattr(path, "is_junction", None)
    return stat.S_ISLNK(metadata.st_mode) or path.is_symlink() or \
        (is_junction is not None and is_junction())


def lexical_absolute(path: Path) -> Path:
    candidate = Path(os.path.abspath(os.fspath(path)))
    if sys.platform == "darwin":
        for alias, canonical in _DARWIN_SYSTEM_ALIASES.items():
            try:
                relative = candidate.relative_to(alias)
            except ValueError:
                continue
            try:
                if alias.is_symlink() and alias.resolve(strict=True) == canonical:
                    return canonical / relative
            except OSError:
                pass
    return candidate


def _components(path: Path) -> tuple[Path, tuple[str, ...]]:
    parts = path.parts
    if not path.is_absolute() or not parts:
        raise ValueError(f"output path must be absolute: {path}")
    anchor = Path(path.anchor)
    return anchor, tuple(parts[1:])


def verify_directory_chain(path: Path, *, create: bool = False,
                           allow_missing: bool = False) -> Path:
    path = lexical_absolute(path)
    current, parts = _components(path)
    for part in parts:
        current = current / part
        try:
            metadata = current.lstat()
        except FileNotFoundError:
            if create:
                try:
                    os.mkdir(current, 0o755)
                except FileExistsError:
                    pass
                metadata = current.lstat()
            elif allow_missing:
                return path
            else:
                raise ValueError(f"output directory is missing: {current}")
        if _is_link_like(current, metadata):
            raise ValueError(f"output directory path contains a symlink: {current}")
        if not stat.S_ISDIR(metadata.st_mode):
            raise ValueError(f"output directory path contains a special/non-directory entry: {current}")
    return path


def repository_root(repo: Path) -> Path:
    return verify_directory_chain(repo)


def safe_target_root(repo: Path, *, create: bool = True) -> Path:
    root = repository_root(repo)
    target = root / "target"
    verified = verify_directory_chain(target, create=create)
    if verified != root / "target":
        raise ValueError("output root must be the canonical repository target directory")
    return verified


def safe_regular_file(path: Path, *, description: str = "file") -> Path:
    """Return one canonical regular file without following symlinked components."""
    candidate = lexical_absolute(path)
    verify_directory_chain(candidate.parent)
    try:
        metadata = candidate.lstat()
    except FileNotFoundError as error:
        raise ValueError(f"{description} does not exist: {candidate}") from error
    if _is_link_like(candidate, metadata) or not stat.S_ISREG(metadata.st_mode):
        raise ValueError(f"{description} must be a canonical regular non-symlink file: {candidate}")
    return candidate


def safe_output_file(path: Path, *, create_parent: bool = True,
                     description: str = "output file") -> Path:
    """Prepare one lexical output path without following parent/final symlinks."""
    candidate = lexical_absolute(path)
    verify_directory_chain(candidate.parent, create=create_parent)
    try:
        metadata = candidate.lstat()
    except FileNotFoundError:
        return candidate
    if _is_link_like(candidate, metadata) or not stat.S_ISREG(metadata.st_mode):
        raise ValueError(f"{description} must be a regular non-symlink file: {candidate}")
    return candidate


def safe_output_directory(repo: Path, directory: Path, *, create: bool = False,
                          allow_missing: bool = False) -> Path:
    target = safe_target_root(repo, create=True)
    output = lexical_absolute(directory)
    try:
        output.relative_to(target)
    except ValueError as error:
        raise ValueError("output directory must be inside the canonical repository target") from error
    verified = verify_directory_chain(
        output, create=create, allow_missing=allow_missing,
    )
    if verified != output:
        raise ValueError("output directory identity changed during verification")
    return verified


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--directory", type=Path)
    parser.add_argument("--create", action="store_true")
    parser.add_argument("--allow-missing", action="store_true")
    args = parser.parse_args()
    try:
        root = repository_root(args.repo)
        directory = args.directory or root / "target"
        verified = safe_output_directory(
            root, directory, create=args.create,
            allow_missing=args.allow_missing,
        )
    except (OSError, ValueError) as error:
        parser.error(str(error))
    print(verified)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
