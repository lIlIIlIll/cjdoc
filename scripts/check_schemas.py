#!/usr/bin/env python3
"""Compare the real CLI schema exports against the controlled publication set."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
from repository_inputs.contracts import SCHEMA_NAMES
from repository_inputs.files import verify_schema_set
from safe_output_root import safe_output_directory, safe_output_file, verify_directory_chain


# The unqualified CLI alias points at v2, but the unqualified published file
# still denotes the frozen v1. Every other CLI name matches its file stem.
SCHEMA_EXPORTS = {
    stem: "navigation-index-v1" if stem == "navigation-index" else stem
    for stem in SCHEMA_NAMES
}
EXTRA_COMMANDS = {"navigation-index", "search-contract"}


def schema_command(binary: Path, name: str) -> bytes:
    result = subprocess.run([binary, "schema", name], capture_output=True, timeout=30)
    if result.returncode:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise ValueError(f"schema {name} exited {result.returncode}: {detail}")
    return result.stdout.replace(b"\r\n", b"\n")


def check_exports(repo: Path, binary: Path, output: Path) -> None:
    verify_schema_set(repo)
    names = schema_command(binary, "list").decode("utf-8").splitlines()
    actual = set(names)
    expected = set(SCHEMA_EXPORTS.values()) | EXTRA_COMMANDS
    if len(actual) != len(names) or actual != expected:
        raise ValueError(f"schema list differs from the publication registry: "
                         f"missing={sorted(expected - actual)}, unexpected={sorted(actual - expected)}, "
                         f"duplicates={len(actual) != len(names)}")
    for stem, name in SCHEMA_EXPORTS.items():
        filename = f"{stem}.schema.json"
        expected_schema = (repo / "docs" / "schema" / filename).read_bytes()
        actual_schema = schema_command(binary, name)
        safe_output_file(output / filename, create_parent=False).write_bytes(actual_schema)
        if actual_schema != expected_schema:
            raise ValueError(f"schema {name} differs from docs/schema/{filename}")
        if stem == "navigation-index-v2" and schema_command(binary, "navigation-index") != expected_schema:
            raise ValueError("schema navigation-index must match docs/schema/navigation-index-v2.schema.json")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--binary", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        repo = args.repo.resolve(strict=True)
        default_binary = repo / "target" / "release" / "bin" / ("main.exe" if os.name == "nt" else "main")
        binary = (args.binary or default_binary).resolve(strict=True)
        output = (verify_directory_chain(args.output, create=True) if args.output is not None else
                  safe_output_directory(repo, repo / "target" / "schema-check", create=True))
        check_exports(repo, binary, output)
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        parser.exit(1, f"check_schemas: {error}\n")
    print(f"verified {len(SCHEMA_EXPORTS)} published schemas against the CLI")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
