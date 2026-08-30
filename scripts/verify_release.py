#!/usr/bin/env python3
"""Fail-closed release metadata and dependency verification for cjdoc."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
import tomllib


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
        json.dump(value, stream, ensure_ascii=False, indent=2, sort_keys=True)
        stream.write("\n")
        temporary = Path(stream.name)
    os.replace(temporary, path)


def verify_repository(repo: Path, tag: str | None) -> dict[str, object]:
    manifest_path = repo / "cjpm.toml"
    lock_path = repo / "cjpm.lock"
    schema_path = repo / "docs/schema/doc-ir-v7.schema.json"
    alias_schema_path = repo / "docs/schema/doc-ir.schema.json"
    baseline_path = repo / "tests/perf/baseline.json"
    for path in (manifest_path, lock_path, schema_path, alias_schema_path, baseline_path):
        if not path.is_file():
            raise ValueError(f"required release input is missing: {path.relative_to(repo)}")

    manifest = tomllib.loads(manifest_path.read_text(encoding="utf-8"))
    package = manifest.get("package", {})
    version = package.get("version")
    if not isinstance(version, str) or not SEMVER.fullmatch(version):
        raise ValueError("package.version must be a stable three-part SemVer")
    if tag is not None and tag != f"v{version}":
        raise ValueError(f"release tag {tag!r} does not match package version v{version}")

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

    v7_schema = json.loads(schema_path.read_text(encoding="utf-8"))
    alias_schema = json.loads(alias_schema_path.read_text(encoding="utf-8"))
    expected = "cjdoc.doc-ir/7"
    for name, schema in (("doc-ir-v7", v7_schema), ("doc-ir", alias_schema)):
        actual = schema.get("properties", {}).get("schemaVersion", {}).get("const")
        if actual != expected:
            raise ValueError(f"{name} schema does not declare {expected}")

    baseline = json.loads(baseline_path.read_text(encoding="utf-8"))
    if baseline.get("schemaVersion") != "cjdoc.perf-baseline/1":
        raise ValueError("unknown performance baseline schema")
    if baseline.get("state") != "frozen":
        raise ValueError("performance baseline is not frozen")

    inputs = [manifest_path, lock_path, schema_path, alias_schema_path, baseline_path,
              repo / "README.md", repo / "LICENSE"]
    return {
        "schemaVersion": "cjdoc.release-evidence/1",
        "version": version,
        "tag": tag,
        "docIrSchemaVersion": expected,
        "pinnedGitDependencies": pinned_dependencies,
        "inputSha256": {
            str(path.relative_to(repo)).replace(os.sep, "/"): sha256(path)
            for path in inputs
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--tag", default=os.environ.get("CJDOC_RELEASE_TAG"))
    parser.add_argument("--evidence", type=Path)
    args = parser.parse_args()
    repo = args.repo.resolve()
    try:
        evidence = verify_repository(repo, args.tag)
    except (OSError, ValueError, tomllib.TOMLDecodeError, json.JSONDecodeError) as error:
        parser.error(str(error))
    if args.evidence:
        atomic_json(args.evidence.resolve(), evidence)
    print(json.dumps(evidence, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
