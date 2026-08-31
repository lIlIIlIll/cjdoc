#!/usr/bin/env python3
"""Create and re-verify immutable fixture inputs for golden generation."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tarfile
import tempfile
from typing import Any

try:
    from .safe_output_root import lexical_absolute, verify_directory_chain
    from .strict_json import strict_dumps, strict_load
except ImportError:  # Direct script execution.
    from safe_output_root import lexical_absolute, verify_directory_chain
    from strict_json import strict_dumps, strict_load


OBJECT_ID = re.compile(r"^[0-9a-f]{40}$")
FIXTURE_RELATIVE = Path("tests/fixtures/projects")
SOURCE_EDGES_RELATIVE = FIXTURE_RELATIVE / "source_edges"


def git(repo: Path, *args: str, text: bool = True) -> str | bytes:
    result = subprocess.run(
        ["git", "-c", "core.hooksPath=/dev/null", "-C", str(repo), *args],
        check=False,
        capture_output=True,
        text=text,
    )
    if result.returncode != 0:
        stderr = result.stderr.strip() if text else result.stderr.decode(errors="replace").strip()
        raise ValueError(f"git {' '.join(args)} failed: {stderr}")
    return result.stdout


def git_object(repo: Path, revision: str) -> str:
    value = str(git(repo, "rev-parse", "--verify", revision)).strip()
    if not OBJECT_ID.fullmatch(value):
        raise ValueError(f"Git returned an invalid object id for {revision!r}")
    return value


def repository_root(path: Path) -> Path:
    root = lexical_absolute(Path(str(git(path, "rev-parse", "--show-toplevel")).strip()))
    try:
        verify_directory_chain(root)
    except ValueError as error:
        raise ValueError(f"Git top-level is not a directory: {root}") from error
    if not root.is_dir():
        raise ValueError(f"Git top-level is not a directory: {root}")
    return root


def scoped_status(repo: Path, relative: Path, *, exclude: Path | None = None) -> str:
    args = ["status", "--porcelain=v1", "--untracked-files=all", "--", relative.as_posix()]
    if exclude is not None:
        args.append(f":(exclude){exclude.as_posix()}")
    return str(git(repo, *args))


def tree_digest(root: Path) -> str:
    if root.is_symlink() or not root.is_dir():
        raise ValueError(f"fixture snapshot root must be a regular directory: {root}")
    digest = hashlib.sha256()
    for path in sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix()):
        relative = path.relative_to(root).as_posix().encode("utf-8")
        mode = path.lstat().st_mode
        if stat.S_ISLNK(mode) or not (stat.S_ISDIR(mode) or stat.S_ISREG(mode)):
            raise ValueError(f"fixture snapshot contains an unsupported entry: {relative!r}")
        kind = b"D" if stat.S_ISDIR(mode) else b"F"
        digest.update(kind + b"\0" + relative + b"\0")
        if stat.S_ISREG(mode):
            digest.update(f"{stat.S_IMODE(mode):04o}".encode("ascii") + b"\0")
            with path.open("rb") as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(block)
            digest.update(b"\0")
    return digest.hexdigest()


def inventory_entry(digest, kind: bytes, relative: str,
                    *, executable: bool = False, content: bytes | None = None,
                    path: Path | None = None) -> None:
    digest.update(kind + b"\0" + relative.encode("utf-8") + b"\0")
    if kind == b"F":
        digest.update(b"X\0" if executable else b"N\0")
        content_digest = hashlib.sha256()
        size = 0
        if content is not None:
            content_digest.update(content)
            size = len(content)
        elif path is not None:
            with path.open("rb") as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b""):
                    content_digest.update(block)
                    size += len(block)
        else:
            raise AssertionError("file inventory entry omits its content")
        digest.update(str(size).encode("ascii") + b"\0" + content_digest.digest())


def committed_inventory_digest(repo: Path, commit: str, relative: Path,
                               expected_tree: str) -> str:
    raw = git(
        repo, "ls-tree", "-r", "-t", "-z", commit, "--", relative.as_posix(),
        text=False,
    )
    assert isinstance(raw, bytes)
    prefix = relative.as_posix() + "/" if relative != Path(".") else ""
    digest = hashlib.sha256()
    found_root = relative == Path(".")
    for record in (item for item in raw.split(b"\0") if item):
        metadata, separator, raw_name = record.partition(b"\t")
        fields = metadata.split()
        if separator != b"\t" or len(fields) != 3:
            raise ValueError("source_edges committed tree inventory is malformed")
        mode, kind, raw_object = fields
        try:
            name = raw_name.decode("utf-8", "strict")
            object_id = raw_object.decode("ascii", "strict")
        except UnicodeDecodeError as error:
            raise ValueError("source_edges committed tree inventory is not UTF-8") from error
        if not OBJECT_ID.fullmatch(object_id):
            raise ValueError("source_edges committed tree has an invalid object id")
        if relative != Path(".") and name == relative.as_posix():
            if kind != b"tree" or object_id != expected_tree:
                raise ValueError("source_edges committed subtree identity is inconsistent")
            found_root = True
            continue
        if relative != Path(".") and kind == b"tree" and \
                relative.as_posix().startswith(name + "/"):
            continue
        if prefix and not name.startswith(prefix):
            raise ValueError("source_edges committed tree escaped its subtree")
        local_name = name[len(prefix):] if prefix else name
        if not local_name or local_name.startswith("/"):
            raise ValueError("source_edges committed tree contains an invalid path")
        if kind == b"tree" and mode == b"040000":
            inventory_entry(digest, b"D", local_name)
        elif kind == b"blob" and mode in (b"100644", b"100755"):
            content = git(repo, "cat-file", "blob", object_id, text=False)
            assert isinstance(content, bytes)
            inventory_entry(
                digest, b"F", local_name,
                executable=mode == b"100755", content=content,
            )
        else:
            raise ValueError(
                f"source_edges committed tree contains an unsupported entry: {local_name}"
            )
    if not found_root:
        raise ValueError("source_edges committed subtree is missing")
    return digest.hexdigest()


def working_inventory_digest(project: Path, *, repository_root: Path) -> str:
    if project.is_symlink() or not project.is_dir():
        raise ValueError("source_edges override must be a regular directory")
    digest = hashlib.sha256()
    for path in sorted(project.rglob("*"), key=lambda item: item.relative_to(project).as_posix()):
        relative_path = path.relative_to(project)
        if project == repository_root and relative_path.parts[0] == ".git":
            continue
        relative = relative_path.as_posix()
        mode = path.lstat().st_mode
        if stat.S_ISDIR(mode):
            inventory_entry(digest, b"D", relative)
        elif stat.S_ISREG(mode):
            inventory_entry(
                digest, b"F", relative,
                executable=bool(mode & 0o111), path=path,
            )
        else:
            raise ValueError(
                f"source_edges override contains a symlink or special file: {relative}"
            )
    return digest.hexdigest()


def extract_git_tree(repo: Path, commit: str, relative: Path, destination: Path) -> None:
    archive = git(repo, "archive", "--format=tar", commit, "--", relative.as_posix(), text=False)
    assert isinstance(archive, bytes)
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:") as package:
        package.extractall(destination, filter="data")


def override_identity(
    project: Path, expected_commit: str, expected_tree: str,
) -> dict[str, str]:
    project = lexical_absolute(project)
    try:
        verify_directory_chain(project)
    except ValueError as error:
        raise ValueError("source_edges override must be a canonical regular directory") from error
    if not project.is_dir():
        raise ValueError("source_edges override must be a canonical regular directory")
    root = repository_root(project)
    try:
        # Normalize Windows 8.3/long-name spelling after both chains were
        # verified to contain no symlink or junction components.
        relative = project.resolve(strict=True).relative_to(root.resolve(strict=True))
    except ValueError as error:
        raise ValueError("source_edges override must be inside its Git worktree") from error
    if relative == Path("."):
        tree_revision = f"{expected_commit}^{{tree}}"
    else:
        tree_revision = f"{expected_commit}:{relative.as_posix()}"
    if not OBJECT_ID.fullmatch(expected_commit) or not OBJECT_ID.fullmatch(expected_tree):
        raise ValueError("source_edges expected commit and tree must be lowercase 40-hex ids")
    head = git_object(root, "HEAD^{commit}")
    if head != expected_commit:
        raise ValueError(f"source_edges override HEAD {head} does not match {expected_commit}")
    tree = git_object(root, tree_revision)
    if tree != expected_tree:
        raise ValueError(f"source_edges override tree {tree} does not match {expected_tree}")
    committed_digest = committed_inventory_digest(root, head, relative, tree)
    working_digest = working_inventory_digest(project, repository_root=root)
    if working_digest != committed_digest:
        raise ValueError(
            "source_edges override inventory/mode/bytes do not match the exact committed tree"
        )
    return {
        "root": str(root),
        "relative": relative.as_posix(),
        "commit": head,
        "tree": tree,
        "workingTreeSha256": working_digest,
    }


def write_receipt(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", dir=path.parent, prefix=f".{path.name}.", delete=False
    ) as stream:
        stream.write(strict_dumps(value, indent=2, sort_keys=True))
        stream.write("\n")
        temporary = Path(stream.name)
    os.replace(temporary, path)


def prepare(
    repo: Path,
    destination: Path,
    receipt_path: Path,
    *,
    override: Path | None = None,
    expected_commit: str | None = None,
    expected_tree: str | None = None,
) -> dict[str, Any]:
    repo = repository_root(repo)
    destination = destination.resolve()
    if destination.exists():
        raise ValueError(f"fixture snapshot destination already exists: {destination}")
    commit = git_object(repo, "HEAD^{commit}")
    fixtures_tree = git_object(repo, f"{commit}:{FIXTURE_RELATIVE.as_posix()}")
    excluded = SOURCE_EDGES_RELATIVE if override is not None else None
    status = scoped_status(repo, FIXTURE_RELATIVE, exclude=excluded)
    if status:
        raise ValueError("refusing mixed or dirty repository fixture inputs:\n" + status)
    if override is None and (expected_commit is not None or expected_tree is not None):
        raise ValueError("source_edges identity was provided without an override")
    if override is not None and (not expected_commit or not expected_tree):
        raise ValueError("source_edges override requires expected commit and subtree tree ids")

    override_before = None
    if override is not None:
        override_before = override_identity(override, expected_commit or "", expected_tree or "")
        override_before["workingTreeSha256Before"] = override_before.pop(
            "workingTreeSha256"
        )

    destination.mkdir(parents=True)
    try:
        extract_git_tree(repo, commit, FIXTURE_RELATIVE, destination)
        snapshot_root = destination / FIXTURE_RELATIVE
        if override_before is not None:
            target = destination / SOURCE_EDGES_RELATIVE
            if target.exists():
                shutil.rmtree(target)
            override_root = Path(override_before["root"])
            override_relative = Path(override_before["relative"])
            with tempfile.TemporaryDirectory(dir=destination, prefix=".source-edges-") as raw:
                contents = Path(raw) / "contents"
                contents.mkdir()
                extract_git_tree(
                    override_root,
                    override_before["commit"],
                    override_relative,
                    contents,
                )
                extracted = contents if override_relative == Path(".") \
                    else contents / override_relative
                target.parent.mkdir(parents=True, exist_ok=True)
                os.replace(extracted, target)
        digest = tree_digest(snapshot_root)
        receipt: dict[str, Any] = {
            "schemaVersion": "cjdoc.fixture-snapshot/1",
            "repository": {
                "root": str(repo),
                "commit": commit,
                "fixturesTree": fixtures_tree,
            },
            "sourceEdgesOverride": override_before,
            "snapshot": {
                "root": str(snapshot_root),
                "sha256": digest,
            },
        }
        write_receipt(receipt_path, receipt)
        return receipt
    except BaseException:
        shutil.rmtree(destination, ignore_errors=True)
        raise


def verify(receipt_path: Path) -> dict[str, Any]:
    value = strict_load(receipt_path, description="fixture snapshot receipt")
    if not isinstance(value, dict) or value.get("schemaVersion") != "cjdoc.fixture-snapshot/1":
        raise ValueError("unknown fixture snapshot receipt")
    repository = value.get("repository")
    snapshot = value.get("snapshot")
    override = value.get("sourceEdgesOverride")
    if not isinstance(repository, dict) or not isinstance(snapshot, dict):
        raise ValueError("fixture snapshot receipt is incomplete")
    repo = Path(repository.get("root", ""))
    commit = repository.get("commit")
    fixtures_tree = repository.get("fixturesTree")
    if not isinstance(commit, str) or not isinstance(fixtures_tree, str):
        raise ValueError("fixture snapshot repository identity is incomplete")
    if git_object(repo, "HEAD^{commit}") != commit or \
            git_object(repo, f"{commit}:{FIXTURE_RELATIVE.as_posix()}") != fixtures_tree:
        raise ValueError("repository fixture identity changed during golden generation")
    excluded = SOURCE_EDGES_RELATIVE if override is not None else None
    status = scoped_status(repo, FIXTURE_RELATIVE, exclude=excluded)
    if status:
        raise ValueError("repository fixtures changed during golden generation:\n" + status)
    if override is not None:
        if not isinstance(override, dict):
            raise ValueError("invalid source_edges override receipt")
        after = override_identity(
            Path(override.get("root", "")) / Path(override.get("relative", "")),
            str(override.get("commit", "")),
            str(override.get("tree", "")),
        )
        expected_override = {
            key: override.get(key) for key in ("root", "relative", "commit", "tree")
        }
        if {key: after.get(key) for key in expected_override} != expected_override or \
                after["workingTreeSha256"] != override.get("workingTreeSha256Before"):
            raise ValueError("source_edges override changed during golden generation")
    snapshot_root = Path(snapshot.get("root", ""))
    expected_digest = snapshot.get("sha256")
    if not isinstance(expected_digest, str) or tree_digest(snapshot_root) != expected_digest:
        raise ValueError("fixture snapshot changed during golden generation")
    value["verifiedAfter"] = {
        "repositoryCommit": commit,
        "repositoryFixturesTree": fixtures_tree,
        "snapshotSha256": expected_digest,
        "sourceEdgesWorkingTreeSha256": (
            after["workingTreeSha256"] if override is not None else None
        ),
    }
    write_receipt(receipt_path, value)
    return value


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    prepare_parser = subparsers.add_parser("prepare")
    prepare_parser.add_argument("--repo", type=Path, required=True)
    prepare_parser.add_argument("--destination", type=Path, required=True)
    prepare_parser.add_argument("--receipt", type=Path, required=True)
    prepare_parser.add_argument("--source-edges-override", type=Path)
    prepare_parser.add_argument("--expected-commit")
    prepare_parser.add_argument("--expected-tree")
    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("--receipt", type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.command == "prepare":
            prepare(
                args.repo,
                args.destination,
                args.receipt,
                override=args.source_edges_override,
                expected_commit=args.expected_commit,
                expected_tree=args.expected_tree,
            )
        else:
            verify(args.receipt)
    except (OSError, ValueError, json.JSONDecodeError, subprocess.SubprocessError) as error:
        print(f"fixture snapshot verification failed: {error}", file=os.sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
