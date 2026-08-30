#!/usr/bin/env python3
"""Commit/tree/dirty identities for evidence-producing tooling."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import re
import stat
import subprocess

try:
    from .safe_output_root import lexical_absolute, verify_directory_chain
    from .worktree_identity import exact_worktree_identity, git_root
except ImportError:  # Direct script execution.
    from safe_output_root import lexical_absolute, verify_directory_chain
    from worktree_identity import exact_worktree_identity, git_root


COMMIT = re.compile(r"^[0-9a-f]{40}$")
IGNORED_UNVERSIONED_DIRECTORIES = {".git", "target", "build-script-cache", "__pycache__"}


def run_git(path: Path, *args: str, text: bool = True) -> str | bytes:
    result = subprocess.run(
        ["git", "-C", str(path), *args],
        text=text, capture_output=True, check=False, timeout=30,
    )
    if result.returncode != 0:
        detail = result.stderr or result.stdout
        if isinstance(detail, bytes):
            rendered = detail.decode("utf-8", "replace").strip()
        else:
            rendered = detail.strip()
        raise ValueError(f"git {' '.join(args)} failed: {rendered}")
    return result.stdout.strip() if text else result.stdout


def file_identity(digest: "hashlib._Hash", root: Path, relative: str) -> None:
    path = root / relative
    metadata = path.lstat()
    digest.update(relative.encode("utf-8"))
    digest.update(b"\0")
    digest.update(f"{stat.S_IMODE(metadata.st_mode):04o}".encode("ascii"))
    digest.update(b"\0")
    if path.is_symlink():
        digest.update(b"L\0")
        digest.update(os.readlink(path).encode("utf-8"))
    elif path.is_file():
        digest.update(b"F\0")
        with path.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
    else:
        raise ValueError(f"unsupported untracked evidence input: {relative}")
    digest.update(b"\0")


def dirty_digest(top: Path) -> str:
    digest = hashlib.sha256()
    diff = run_git(top, "diff", "--binary", "--no-ext-diff", "HEAD", "--", text=False)
    assert isinstance(diff, bytes)
    digest.update(b"diff\0")
    digest.update(diff)
    untracked = run_git(top, "ls-files", "--others", "--exclude-standard", "-z", text=False)
    assert isinstance(untracked, bytes)
    for raw in sorted(value for value in untracked.split(b"\0") if value):
        relative = raw.decode("utf-8", "strict")
        file_identity(digest, top, relative)
    return digest.hexdigest()


def unversioned_digest(root: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix()):
        relative_path = path.relative_to(root)
        if any(part in IGNORED_UNVERSIONED_DIRECTORIES for part in relative_path.parts):
            continue
        if path.is_dir() and not path.is_symlink():
            continue
        file_identity(digest, root, relative_path.as_posix())
    return digest.hexdigest()


def source_identity(path: Path, *, allow_dirty: bool = False) -> dict[str, object]:
    path = lexical_absolute(path)
    try:
        verify_directory_chain(path)
    except ValueError as error:
        raise ValueError(f"evidence source must be a regular directory: {path}") from error
    if not path.is_dir():
        raise ValueError(f"evidence source must be a regular directory: {path}")
    try:
        return exact_worktree_identity(path)
    except ValueError as identity_error:
        if not allow_dirty:
            raise
        try:
            top = git_root(path)
        except ValueError:
            return {
                "kind": "unversioned",
                "headCommit": None,
                "tree": None,
                "pathRelative": ".",
                "pathTree": None,
                "dirty": True,
                "trustedCommit": False,
                "workingTreeSha256": unversioned_digest(path),
                "identityError": str(identity_error),
            }
        try:
            # Git can return a long Windows path for a verified 8.3 input.
            relative = path.resolve(strict=True).relative_to(top.resolve(strict=True))
        except ValueError as error:
            raise ValueError("evidence source is outside its Git top-level") from error
        head = run_git(top, "rev-parse", "--verify", "HEAD^{commit}")
        tree = run_git(top, "rev-parse", "--verify", "HEAD^{tree}")
        assert isinstance(head, str) and isinstance(tree, str)
        path_tree: str | None = tree
        if relative != Path("."):
            try:
                candidate = run_git(
                    top, "rev-parse", "--verify", f"HEAD:{relative.as_posix()}"
                )
                assert isinstance(candidate, str)
                object_type = run_git(top, "cat-file", "-t", candidate)
                assert isinstance(object_type, str)
                if not COMMIT.fullmatch(candidate) or object_type != "tree":
                    raise ValueError("requested project is not a committed directory")
                path_tree = candidate
            except ValueError:
                path_tree = None
        digest = hashlib.sha256()
        digest.update(unversioned_digest(path).encode("ascii"))
        digest.update(b"\0")
        digest.update(str(identity_error).encode("utf-8"))
        return {
            "kind": "git",
            "headCommit": head,
            "tree": tree,
            "pathRelative": "." if relative == Path(".") else relative.as_posix(),
            "pathTree": path_tree,
            "dirty": True,
            "trustedCommit": False,
            "workingTreeSha256": digest.hexdigest(),
            "identityError": str(identity_error),
        }
