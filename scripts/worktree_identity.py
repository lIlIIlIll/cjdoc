#!/usr/bin/env python3
"""Exact HEAD/index/worktree identity checks for release and evidence inputs."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import os
from pathlib import Path
import re
import stat
import subprocess

try:
    from .safe_output_root import lexical_absolute, verify_directory_chain
except ImportError:  # Direct script execution.
    from safe_output_root import lexical_absolute, verify_directory_chain


OBJECT_ID = re.compile(r"^[0-9a-f]{40}$")
PROBE_GENERATED_SUFFIXES = (".cjo", ".chir", ".chirtxt")
GENERATED_PROBES = {
    "probes/ast_lexer/probe_ast_lexer",
    "probes/ast_parser/probe_ast_parser",
    "probes/chir_loader/local_chir_loader",
}


@dataclass(frozen=True)
class HeadEntry:
    mode: str
    kind: str
    object_id: str


def run_git(repo: Path, *args: str, text: bool = True) -> str | bytes:
    result = subprocess.run(
        ["git", "-C", str(repo), *args],
        text=text, capture_output=True, check=False, timeout=60,
    )
    if result.returncode != 0:
        detail = result.stderr or result.stdout
        rendered = detail.decode("utf-8", "replace").strip() \
            if isinstance(detail, bytes) else detail.strip()
        raise ValueError(f"git {' '.join(args)} failed: {rendered}")
    return result.stdout.strip() if text else result.stdout


def git_root(path: Path) -> Path:
    value = run_git(path, "rev-parse", "--show-toplevel")
    assert isinstance(value, str)
    root = lexical_absolute(Path(value))
    try:
        verify_directory_chain(root)
    except ValueError as error:
        raise ValueError("worktree Git top-level must be a regular directory") from error
    if not root.is_dir():
        raise ValueError("worktree Git top-level must be a regular directory")
    return root


def parse_head_entries(repo: Path, commit: str) -> dict[str, HeadEntry]:
    raw = run_git(repo, "ls-tree", "-r", "-z", commit, text=False)
    assert isinstance(raw, bytes)
    result: dict[str, HeadEntry] = {}
    for record in (item for item in raw.split(b"\0") if item):
        metadata, separator, raw_name = record.partition(b"\t")
        fields = metadata.split()
        if separator != b"\t" or len(fields) != 3:
            raise ValueError("HEAD tree inventory is malformed")
        mode, kind, raw_object = fields
        try:
            name = raw_name.decode("utf-8", "strict")
            entry = HeadEntry(
                mode.decode("ascii"), kind.decode("ascii"),
                raw_object.decode("ascii"),
            )
        except UnicodeDecodeError as error:
            raise ValueError("HEAD tree inventory contains a non-UTF-8 path") from error
        if name in result or not OBJECT_ID.fullmatch(entry.object_id):
            raise ValueError("HEAD tree inventory contains an invalid entry")
        if (entry.kind, entry.mode) not in {
            ("blob", "100644"), ("blob", "100755"), ("blob", "120000")
        }:
            raise ValueError(f"unsupported tracked worktree entry: {name}")
        result[name] = entry
    return result


def parse_index_entries(repo: Path) -> dict[str, HeadEntry]:
    raw = run_git(repo, "ls-files", "--stage", "-z", text=False)
    assert isinstance(raw, bytes)
    result: dict[str, HeadEntry] = {}
    for record in (item for item in raw.split(b"\0") if item):
        metadata, separator, raw_name = record.partition(b"\t")
        fields = metadata.split()
        if separator != b"\t" or len(fields) != 3 or fields[2] != b"0":
            raise ValueError("worktree index contains an unmerged or malformed entry")
        try:
            name = raw_name.decode("utf-8", "strict")
            entry = HeadEntry(
                fields[0].decode("ascii"), "blob", fields[1].decode("ascii")
            )
        except UnicodeDecodeError as error:
            raise ValueError("worktree index contains a non-UTF-8 path") from error
        if name in result:
            raise ValueError("worktree index contains a duplicate path")
        result[name] = entry
    return result


def verify_index_flags(repo: Path, expected_paths: set[str]) -> None:
    raw = run_git(repo, "ls-files", "-v", "-z", text=False)
    assert isinstance(raw, bytes)
    flags: dict[str, str] = {}
    for record in (item for item in raw.split(b"\0") if item):
        flag, separator, raw_name = record.partition(b" ")
        if separator != b" " or len(flag) != 1:
            raise ValueError("worktree index flags are malformed")
        try:
            name = raw_name.decode("utf-8", "strict")
            rendered_flag = flag.decode("ascii")
        except UnicodeDecodeError as error:
            raise ValueError("worktree index flags contain a non-UTF-8 path") from error
        flags[name] = rendered_flag
    if set(flags) != expected_paths:
        raise ValueError("worktree index inventory does not match HEAD")
    hidden = sorted(name for name, flag in flags.items() if flag != "H")
    if hidden:
        raise ValueError(
            "worktree index uses assume-unchanged/skip-worktree or another hidden state: "
            + hidden[0]
        )


def allowed_generated_path(relative: str) -> bool:
    path = Path(relative)
    parts = path.parts
    if not parts:
        return False
    if parts[0] in {"target", "build-script-cache"}:
        return True
    if "__pycache__" in parts:
        # The directory itself may be left behind by Python tooling, but its
        # bytecode is executable input: unchecked-hash pyc files can override
        # the corresponding source even when that source has changed.
        return parts[-1] == "__pycache__"
    return relative in GENERATED_PROBES or \
        (parts[0] == "probes" and relative.endswith(PROBE_GENERATED_SUFFIXES))


def hash_regular_blob(path: Path, metadata: os.stat_result) -> tuple[str, bytes]:
    """Return the Git SHA-1 and content SHA-256 without following a final symlink."""
    git_digest = hashlib.sha1(usedforsecurity=False)
    git_digest.update(f"blob {metadata.st_size}\0".encode("ascii"))
    content_digest = hashlib.sha256()
    flags = os.O_RDONLY
    if hasattr(os, "O_BINARY"):
        flags |= os.O_BINARY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags)
    try:
        opened = os.fstat(descriptor)
        if not stat.S_ISREG(opened.st_mode) or (opened.st_dev, opened.st_ino) != \
                (metadata.st_dev, metadata.st_ino) or opened.st_size != metadata.st_size:
            raise ValueError(f"tracked file changed while inspected: {path}")
        while True:
            block = os.read(descriptor, 1024 * 1024)
            if not block:
                break
            git_digest.update(block)
            content_digest.update(block)
    finally:
        os.close(descriptor)
    return git_digest.hexdigest(), content_digest.digest()


def scope_entries(entries: dict[str, HeadEntry], relative: Path) -> dict[str, HeadEntry]:
    if relative == Path("."):
        return entries
    prefix = relative.as_posix() + "/"
    return {
        name: entry for name, entry in entries.items()
        if name.startswith(prefix)
    }


def expected_directories(paths: set[str], relative: Path) -> set[str]:
    prefix = "" if relative == Path(".") else relative.as_posix() + "/"
    result: set[str] = set()
    for name in paths:
        local = name[len(prefix):]
        parts = Path(local).parts
        for index in range(1, len(parts)):
            result.add(Path(*parts[:index]).as_posix())
    return result


def verify_working_files(repo: Path, scope: Path,
                         entries: dict[str, HeadEntry]) -> str:
    relative_scope = scope.resolve(strict=True).relative_to(repo.resolve(strict=True))
    prefix = "" if relative_scope == Path(".") else relative_scope.as_posix() + "/"
    scoped = scope_entries(entries, relative_scope)
    if relative_scope != Path(".") and not scoped:
        raise ValueError(f"evidence source is not represented in HEAD: {scope}")
    expected_files = set(scoped)
    expected_dirs = expected_directories(expected_files, relative_scope)
    observed_files: set[str] = set()
    digest = hashlib.sha256()

    for path in sorted(scope.rglob("*"), key=lambda item: item.relative_to(scope).as_posix()):
        local = path.relative_to(scope).as_posix()
        repository_relative = prefix + local
        if relative_scope == Path(".") and Path(local).parts[0] == ".git":
            continue
        metadata = path.lstat()
        if repository_relative not in expected_files and local not in expected_dirs and \
                allowed_generated_path(repository_relative):
            continue
        if stat.S_ISDIR(metadata.st_mode):
            if local not in expected_dirs:
                raise ValueError(f"unexpected ignored/untracked worktree directory: {repository_relative}")
            continue
        entry = scoped.get(repository_relative)
        if entry is None:
            raise ValueError(f"unexpected ignored/untracked worktree input: {repository_relative}")
        if entry.mode == "120000":
            if not stat.S_ISLNK(metadata.st_mode):
                raise ValueError(f"tracked symlink changed type: {repository_relative}")
            content = os.readlink(path).encode("utf-8")
            git_digest = hashlib.sha1(usedforsecurity=False)
            git_digest.update(f"blob {len(content)}\0".encode("ascii"))
            git_digest.update(content)
            object_id = git_digest.hexdigest()
            content_sha256 = hashlib.sha256(content).digest()
        else:
            if not stat.S_ISREG(metadata.st_mode):
                raise ValueError(f"tracked file changed type: {repository_relative}")
            if os.name != "nt" and bool(metadata.st_mode & 0o111) != (entry.mode == "100755"):
                raise ValueError(f"tracked file executable mode changed: {repository_relative}")
            object_id, content_sha256 = hash_regular_blob(path, metadata)
        if object_id != entry.object_id:
            raise ValueError(f"tracked worktree bytes differ from HEAD: {repository_relative}")
        observed_files.add(repository_relative)
        digest.update(entry.mode.encode("ascii") + b"\0")
        digest.update(repository_relative.encode("utf-8") + b"\0")
        digest.update(content_sha256)
    missing = sorted(expected_files - observed_files)
    if missing:
        raise ValueError(f"tracked worktree input is missing: {missing[0]}")
    return digest.hexdigest()


def exact_worktree_identity(path: Path, expected_commit: str | None = None) -> dict[str, object]:
    scope = lexical_absolute(path)
    try:
        verify_directory_chain(scope)
    except ValueError as error:
        raise ValueError(f"evidence source must be a regular directory: {scope}") from error
    if not scope.is_dir():
        raise ValueError(f"evidence source must be a regular directory: {scope}")
    repo = git_root(scope)
    try:
        # Windows may spell the same verified directory through an 8.3 alias
        # while Git returns its long name. Resolve only after every component
        # has passed the no-symlink/no-junction chain check above.
        relative = scope.resolve(strict=True).relative_to(repo.resolve(strict=True))
    except ValueError as error:
        raise ValueError("evidence source is outside its Git top-level") from error
    head = run_git(repo, "rev-parse", "--verify", "HEAD^{commit}")
    tree = run_git(repo, "rev-parse", "--verify", "HEAD^{tree}")
    assert isinstance(head, str) and isinstance(tree, str)
    if not OBJECT_ID.fullmatch(head) or not OBJECT_ID.fullmatch(tree):
        raise ValueError("worktree HEAD has an invalid identity")
    if expected_commit is not None and head != expected_commit:
        raise ValueError(f"worktree HEAD {head} does not match {expected_commit}")
    head_entries = parse_head_entries(repo, head)
    index_entries = parse_index_entries(repo)
    if index_entries != head_entries:
        raise ValueError("worktree index mode/blob inventory does not match HEAD")
    verify_index_flags(repo, set(head_entries))
    digest = verify_working_files(repo, scope, head_entries)
    if relative == Path("."):
        path_tree = tree
    else:
        value = run_git(repo, "rev-parse", "--verify", f"HEAD:{relative.as_posix()}")
        assert isinstance(value, str)
        if not OBJECT_ID.fullmatch(value):
            raise ValueError("evidence source subtree has an invalid identity")
        path_tree = value
    return {
        "kind": "git",
        "root": str(repo),
        "headCommit": head,
        "tree": tree,
        "pathRelative": "." if relative == Path(".") else relative.as_posix(),
        "pathTree": path_tree,
        "worktreeSha256": digest,
        "dirty": False,
        "trustedCommit": True,
        "workingTreeSha256": None,
    }
