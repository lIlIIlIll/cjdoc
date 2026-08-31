#!/usr/bin/env python3
"""Fail-closed release metadata and dependency verification for cjdoc."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import tomllib

sys.dont_write_bytecode = True

try:
    from .safe_output_root import lexical_absolute, safe_output_file, verify_directory_chain
    from .strict_json import strict_dumps, strict_load
    from .verify_repository_inputs import required_repository_paths, verify_repository_inputs
    from .worktree_identity import exact_worktree_identity
except ImportError:  # Direct script execution.
    from safe_output_root import lexical_absolute, safe_output_file, verify_directory_chain
    from strict_json import strict_dumps, strict_load
    from verify_repository_inputs import required_repository_paths, verify_repository_inputs
    from worktree_identity import exact_worktree_identity


SEMVER = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
COMMIT = re.compile(r"^[0-9a-f]{40}$")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def atomic_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent,
                                     prefix=f".{path.name}.", delete=False) as stream:
        stream.write(strict_dumps(value, ensure_ascii=False, indent=2, sort_keys=True))
        stream.write("\n")
        temporary = Path(stream.name)
    os.replace(temporary, path)


def run_git(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo), *args],
        text=True, capture_output=True, check=False,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        raise ValueError(f"git {' '.join(args)} failed: {detail}")
    return result.stdout.strip()


def verify_git_identity(repo: Path, tag: str, expected_commit: str | None) -> dict[str, object]:
    top = Path(run_git(repo, "rev-parse", "--show-toplevel")).resolve()
    if top != repo.resolve():
        raise ValueError("release repository must be the Git top-level")
    head = run_git(repo, "rev-parse", "--verify", "HEAD^{commit}")
    tree = run_git(repo, "rev-parse", "--verify", "HEAD^{tree}")
    tag_commit = run_git(repo, "rev-parse", "--verify", f"refs/tags/{tag}^{{commit}}")
    if head != tag_commit:
        raise ValueError(f"release tag {tag!r} does not point to HEAD")
    if expected_commit is not None:
        if not COMMIT.fullmatch(expected_commit):
            raise ValueError("expected release commit must be a lowercase 40-hex commit")
        if expected_commit != head:
            raise ValueError("checked-out HEAD does not match the expected release commit")
    exact = exact_worktree_identity(repo, head)
    return {
        "commit": head,
        "tree": tree,
        "tagCommit": tag_commit,
        "dirty": False,
        "worktreeSha256": exact["worktreeSha256"],
    }


def verify_repository(repo: Path, tag: str | None,
                      expected_commit: str | None = None) -> dict[str, object]:
    repo = lexical_absolute(repo)
    try:
        verify_directory_chain(repo)
    except ValueError as error:
        raise ValueError("release repository must be a canonical regular directory") from error
    if not repo.is_dir():
        raise ValueError("release repository must be a canonical regular directory")
    manifest_path = repo / "cjpm.toml"
    lock_path = repo / "cjpm.lock"
    schema_path = repo / "docs/schema/doc-ir-v8.schema.json"
    legacy_schema_paths = {
        6: repo / "docs/schema/doc-ir-v6.schema.json",
        7: repo / "docs/schema/doc-ir-v7.schema.json",
    }
    alias_schema_path = repo / "docs/schema/doc-ir.schema.json"
    baseline_path = repo / "tests/perf/baseline.json"
    for path in (manifest_path, lock_path, schema_path, *legacy_schema_paths.values(),
                 alias_schema_path, baseline_path):
        if not path.is_file():
            raise ValueError(f"required release input is missing: {path.relative_to(repo)}")

    manifest = tomllib.loads(manifest_path.read_text(encoding="utf-8"))
    package = manifest.get("package", {})
    version = package.get("version")
    if not isinstance(version, str) or not SEMVER.fullmatch(version):
        raise ValueError("package.version must be a stable three-part SemVer")
    if tag is None:
        raise ValueError("release tag is required")
    if tag != f"v{version}":
        raise ValueError(f"release tag {tag!r} does not match package version v{version}")
    repository_inputs = verify_repository_inputs(repo, require_tracked=True)
    git_identity = verify_git_identity(repo, tag, expected_commit)

    dependencies = manifest.get("dependencies", {})
    if not isinstance(dependencies, dict):
        raise ValueError("dependencies must be a TOML table")
    pinned_dependencies: dict[str, str] = {}
    for name, dependency in sorted(dependencies.items()):
        if not isinstance(dependency, dict):
            raise ValueError(f"dependency {name!r} is not an inline table")
        if "git" not in dependency:
            continue
        commit = dependency.get("commitId")
        if not isinstance(commit, str) or not COMMIT.fullmatch(commit):
            raise ValueError(f"git dependency {name!r} is not pinned to a 40-hex commitId")
        if "branch" in dependency or "tag" in dependency:
            raise ValueError(f"git dependency {name!r} also contains a floating branch/tag")
        pinned_dependencies[name] = commit

    lock = tomllib.loads(lock_path.read_text(encoding="utf-8"))
    locked = lock.get("requires", {})
    for name, commit in pinned_dependencies.items():
        entry = locked.get(name) if isinstance(locked, dict) else None
        if not isinstance(entry, dict) or entry.get("commitId") != commit:
            raise ValueError(f"cjpm.lock does not match pinned dependency {name!r}")
        dependency = dependencies[name]
        if entry.get("git") != dependency.get("git"):
            raise ValueError(f"cjpm.lock source does not match pinned dependency {name!r}")
        if "branch" in entry or "tag" in entry:
            raise ValueError(f"cjpm.lock dependency {name!r} contains a floating branch/tag")

    v8_schema = strict_load(schema_path)
    legacy_schemas = {
        legacy_version: strict_load(path)
        for legacy_version, path in legacy_schema_paths.items()
    }
    alias_schema = strict_load(alias_schema_path)
    expected = "cjdoc.doc-ir/8"
    for name, schema in (("doc-ir-v8", v8_schema), ("doc-ir", alias_schema)):
        actual = schema.get("properties", {}).get("schemaVersion", {}).get("const")
        if actual != expected:
            raise ValueError(f"{name} schema does not declare {expected}")
    for legacy_version, legacy_schema in legacy_schemas.items():
        legacy = legacy_schema.get("properties", {}).get("schemaVersion", {}).get("const")
        if legacy != f"cjdoc.doc-ir/{legacy_version}":
            raise ValueError(
                f"doc-ir-v{legacy_version} schema is not frozen at "
                f"cjdoc.doc-ir/{legacy_version}"
            )

    baseline = strict_load(baseline_path)
    if baseline.get("schemaVersion") != "cjdoc.perf-baseline/1":
        raise ValueError("unknown performance baseline schema")
    if baseline.get("state") != "frozen":
        raise ValueError("performance baseline is not frozen")
    if baseline.get("purpose") != "hard-ceiling":
        raise ValueError("performance baseline must declare purpose hard-ceiling")

    inputs = [manifest_path, lock_path, schema_path, *legacy_schema_paths.values(),
              alias_schema_path, baseline_path,
              repo / "README.md", repo / "LICENSE"]
    inputs.extend(repo / relative for relative in required_repository_paths())
    inputs.extend(
        repo / "vendor/yjson_algorithms" / relative
        for relative in repository_inputs["vendor"]["sourceSha256"]
    )
    unique_inputs = {path.resolve(): path for path in inputs}
    return {
        "schemaVersion": "cjdoc.release-evidence/2",
        "version": version,
        "tag": tag,
        **git_identity,
        "docIrSchemaVersion": expected,
        "performanceGateKind": "hard-ceiling",
        "pinnedGitDependencies": pinned_dependencies,
        "vendoredDependencies": {
            "yjson_algorithms": repository_inputs["vendor"],
        },
        "inputSha256": {
            str(path.relative_to(repo)).replace(os.sep, "/"): sha256(path)
            for path in unique_inputs.values()
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--tag", default=os.environ.get("CJDOC_RELEASE_TAG"))
    parser.add_argument("--expected-commit",
                        default=os.environ.get("CJDOC_RELEASE_COMMIT") or os.environ.get("GITHUB_SHA"))
    parser.add_argument("--evidence", type=Path)
    args = parser.parse_args()
    repo = lexical_absolute(args.repo)
    try:
        evidence_path = None
        if args.evidence:
            evidence_path = safe_output_file(
                args.evidence, description="release evidence"
            )
            evidence_path.unlink(missing_ok=True)
        evidence = verify_repository(repo, args.tag, args.expected_commit)
        if evidence_path is not None:
            atomic_json(evidence_path, evidence)
    except (OSError, ValueError, tomllib.TOMLDecodeError, json.JSONDecodeError) as error:
        parser.error(str(error))
    print(json.dumps(evidence, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
