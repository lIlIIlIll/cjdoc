#!/usr/bin/env python3
"""Collect a bounded, identity-labelled diagnostic bundle after a CI failure.

The bundle is evidence only. It never marks an output as an accepted baseline,
never rewrites goldens, and never turns a missing directory into a passing gate:
`if-no-files-found: error` must fail loudly if this script could not write.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import sys

sys.dont_write_bytecode = True

DIAGNOSTICS_SCHEMA = "cjdoc.ci-diagnostics/1"
DEFAULT_MAX_BYTES = 33_554_432
DEFAULT_MAX_FILES = 400
ORIGIN = "failed acceptance output"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def candidate_files(repo: Path, target: Path) -> list[tuple[str, Path]]:
    """Enumerate the labelled failure inputs in a stable order."""
    candidates: list[tuple[str, Path]] = []
    for fixture in sorted({path.name for path in target.glob("*") if path.is_dir()}):
        fixture_root = target / fixture
        for label, relative in (("actual-first", "first/docs.json"), ("actual-second", "second/docs.json")):
            path = fixture_root / relative
            if path.is_file():
                candidates.append((f"{fixture}/{label}", path))
        for stderr in sorted(fixture_root.glob("*.stderr")):
            candidates.append((f"{fixture}/{stderr.name}", stderr))
        diff = fixture_root / "golden.diff"
        if diff.is_file():
            candidates.append((f"{fixture}/golden.diff", diff))
        expected = repo / "tests/fixtures/golden-v11" / f"{fixture}.docs.json"
        if expected.is_file():
            candidates.append((f"{fixture}/expected-golden", expected))
    for record in sorted(target.glob("*.json")):
        candidates.append((f"stage-evidence/{record.name}", record))
    return candidates


def collect(repo: Path, targets: list[Path], out: Path, *, max_bytes: int, max_files: int) -> dict:
    out.mkdir(parents=True, exist_ok=True)
    repository = repo.resolve()
    files: list[dict[str, object]] = []
    omitted: list[dict[str, object]] = []
    collected: set[str] = set()
    total = 0
    available = any(target.is_dir() for target in targets)
    for index, target in enumerate(targets):
        if not target.is_dir():
            continue
        # The golden directory is shared by every root, so the same expected file
        # must never be collected twice; identical sources collapse to one entry.
        prefix = "" if len(targets) == 1 else f"root{index}/"
        for label, source in candidate_files(repo, target):
            key = str(source.resolve())
            if key in collected:
                continue
            collected.add(key)
            size = source.stat().st_size
            if len(files) >= max_files:
                omitted.append({"label": label, "reason": "file budget exhausted"})
                continue
            if total + size > max_bytes:
                omitted.append({"label": label, "reason": "byte budget exhausted", "size": size})
                continue
            try:
                relative = source.resolve().relative_to(repository).as_posix()
            except ValueError:
                relative = f"{prefix}external/{source.name}"
            else:
                relative = f"{prefix}{relative}"
            destination = out / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, destination)
            files.append({"label": f"{prefix}{label}", "path": relative,
                          "sha256": sha256_file(destination), "size": size})
            total += size
    document = {
        "schemaVersion": DIAGNOSTICS_SCHEMA,
        "kind": "failure",
        "acceptedBaseline": False,
        "origin": ORIGIN,
        "available": available,
        "searchedRoots": [str(target) for target in targets],
        "files": files,
        "omitted": omitted,
        "limits": {"maxBytes": max_bytes, "maxFiles": max_files},
    }
    if not available:
        document["reason"] = "no acceptance output directory was produced by the failing run"
    (out / "diagnostics.json").write_text(
        json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8", newline="\n")
    return document


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    collect_parser = commands.add_parser("collect")
    collect_parser.add_argument("--repo", type=Path, required=True)
    collect_parser.add_argument("--target", type=Path, action="append", required=True,
                               help="acceptance output root; repeat for stage-private roots")
    collect_parser.add_argument("--out", type=Path, required=True)
    collect_parser.add_argument("--max-bytes", type=int, default=DEFAULT_MAX_BYTES)
    collect_parser.add_argument("--max-files", type=int, default=DEFAULT_MAX_FILES)
    args = parser.parse_args()
    document = collect(args.repo, list(args.target), args.out,
                       max_bytes=args.max_bytes, max_files=args.max_files)
    # A missing acceptance directory is reported, never re-failed: the upload
    # step's `if-no-files-found: error` is what proves the bundle was written.
    print(f"diagnostics written: {len(document['files'])} files, "
          f"{len(document['omitted'])} omitted, acceptedBaseline=false")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
