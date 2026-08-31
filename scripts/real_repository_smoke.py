#!/usr/bin/env python3
"""Generate a real Cangjie repository twice and verify deterministic artifacts."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True

try:
    from .safe_output_root import safe_output_file, safe_regular_file
    from .source_identity import source_identity as capture_source_identity
    from .strict_json import strict_dumps, strict_load
except ImportError:  # Direct script execution.
    from safe_output_root import safe_output_file, safe_regular_file
    from source_identity import source_identity as capture_source_identity
    from strict_json import strict_dumps, strict_load


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def tree_digests(root: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise ValueError(f"generated artifact is a symlink: {path}")
        if path.is_file():
            result[path.relative_to(root).as_posix()] = file_sha256(path)
    return result


def run(command: list[str], cwd: Path) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        command, cwd=cwd, text=True, capture_output=True, check=False,
        env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
    )
    if result.returncode != 0:
        rendered = " ".join(command)
        raise RuntimeError(
            f"command failed ({result.returncode}): {rendered}\n"
            f"stdout:\n{result.stdout[-4000:]}\nstderr:\n{result.stderr[-4000:]}"
        )
    return result


def source_commit(repo: Path, *, allow_dirty: bool = False) -> str | None:
    identity = capture_source_identity(repo, allow_dirty=allow_dirty)
    return identity["headCommit"] if identity["trustedCommit"] else None


def atomic_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent,
                                     prefix=f".{path.name}.", delete=False) as stream:
        stream.write(strict_dumps(value, ensure_ascii=False, indent=2, sort_keys=True))
        stream.write("\n")
        temporary = Path(stream.name)
    os.replace(temporary, path)


def resolve_binary(value: Path) -> Path:
    candidate = Path(os.path.abspath(os.fspath(value)))
    for executable in (candidate, Path(f"{candidate}.exe")):
        try:
            executable.lstat()
        except FileNotFoundError:
            continue
        return safe_regular_file(executable, description="cjdoc binary")
    raise ValueError(f"cjdoc binary does not exist: {candidate}")


def main() -> int:
    repo = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, default=repo / "target/release/bin/main")
    parser.add_argument("--project", action="append", type=Path, default=[])
    parser.add_argument("--min-declarations", type=int, default=1)
    parser.add_argument("--evidence", type=Path,
                        default=repo / "target/release-evidence/real-repository.json")
    parser.add_argument("--allow-dirty", action="store_true",
                        help="emit explicitly untrusted dirty/unversioned source identities")
    args = parser.parse_args()
    try:
        binary = resolve_binary(args.binary)
        projects = [
            Path(os.path.abspath(os.fspath(path)))
            for path in (args.project or [repo])
        ]
        if args.min_declarations < 1:
            raise ValueError("--min-declarations must be positive")
        for project in projects:
            if not (project / "cjpm.toml").is_file():
                raise ValueError(f"not a cjpm project/workspace: {project}")

        repository_identity = capture_source_identity(repo, allow_dirty=args.allow_dirty)
        project_identities = [
            capture_source_identity(project, allow_dirty=args.allow_dirty)
            for project in projects
        ]
        binary_sha256 = file_sha256(binary)

        evidence_path = safe_output_file(
            args.evidence, description="real-repository evidence"
        )
        evidence_path.unlink(missing_ok=True)
        evidence_root = evidence_path.parent
        summaries: list[dict[str, object]] = []
        with tempfile.TemporaryDirectory(prefix="real-repository-", dir=evidence_root) as temporary:
            work = Path(temporary)
            for index, project in enumerate(projects):
                outputs = [work / f"project-{index}-first", work / f"project-{index}-second"]
                started = time.perf_counter()
                stderr: list[str] = []
                for output in outputs:
                    result = run([
                        str(binary), "generate", "--project", str(project),
                        "--format", "json", "--format", "html",
                        "--output", str(output), "--no-cache",
                    ], repo)
                    stderr.append(result.stderr)
                    run([sys.executable, str(repo / "scripts/validate_html_site.py"),
                         str(output / "html")], repo)
                first = tree_digests(outputs[0])
                second = tree_digests(outputs[1])
                if first != second:
                    missing = sorted(set(first) ^ set(second))
                    changed = sorted(path for path in set(first) & set(second)
                                     if first[path] != second[path])
                    raise ValueError(
                        f"non-deterministic output for {project}: missing={missing}, changed={changed}"
                    )
                document = strict_load(
                    outputs[0] / "docs.json", description="real-repository Doc IR"
                )
                if document.get("schemaVersion") != "cjdoc.doc-ir/8":
                    raise ValueError(f"real repository emitted non-v8 Doc IR: {project}")
                declarations = document.get("declarations")
                diagnostics = document.get("diagnostics")
                if not isinstance(declarations, list) or len(declarations) < args.min_declarations:
                    raise ValueError(f"real repository declaration floor was not met: {project}")
                if not isinstance(diagnostics, list):
                    raise ValueError(f"real repository diagnostics are malformed: {project}")
                errors = sum(item.get("severity") == "error" for item in diagnostics
                             if isinstance(item, dict))
                if errors:
                    raise ValueError(f"real repository produced {errors} error diagnostics: {project}")
                summaries.append({
                    "project": "." if project == repo else project.name,
                    "status": document.get("status"),
                    "declarations": len(declarations),
                    "diagnostics": len(diagnostics),
                    "artifactCount": len(first),
                    "docsSha256": first.get("docs.json"),
                    "elapsedMs": round((time.perf_counter() - started) * 1000),
                    "sourceIdentity": project_identities[index],
                })
        if capture_source_identity(repo, allow_dirty=args.allow_dirty) != repository_identity:
            raise ValueError("cjdoc repository identity changed during real-repository smoke")
        for project, expected_identity in zip(projects, project_identities):
            if capture_source_identity(project, allow_dirty=args.allow_dirty) != expected_identity:
                raise ValueError(f"project identity changed during real-repository smoke: {project}")
        if file_sha256(binary) != binary_sha256:
            raise ValueError("cjdoc binary changed during real-repository smoke")
        evidence = {
            "schemaVersion": "cjdoc.real-repository-smoke/1",
            "sourceCommit": repository_identity["headCommit"]
                if repository_identity["trustedCommit"] else None,
            "sourceIdentity": repository_identity,
            "binarySha256": binary_sha256,
            "projects": summaries,
        }
        atomic_json(evidence_path, evidence)
        print(json.dumps(evidence, ensure_ascii=False, sort_keys=True))
        return 0
    except (OSError, ValueError, RuntimeError, json.JSONDecodeError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    raise SystemExit(main())
