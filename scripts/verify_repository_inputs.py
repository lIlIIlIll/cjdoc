#!/usr/bin/env python3
"""Verify tracked generated inputs, third-party licenses, and vendor provenance."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tomllib
from pathlib import Path

sys.dont_write_bytecode = True

try:
    from .repository_input_contracts import (
        CURRENT_GOLDEN_VERSION,
        GOLDEN_NAMES,
        LEGACY_GOLDEN_VERSIONS,
        SCHEMA_NAMES,
    )
    from .repository_input_files import (
        read_toml,
        required_repository_paths,
        safe_relative,
        sha256,
        validate_schema_document,
        verify_golden_set,
        verify_schema_set,
    )
    from .repository_input_migrations import (
        verify_current_goldens,
        verify_legacy_migrations,
        verify_legacy_receipts,
    )
    from .repository_input_vendor import verify_third_party, verify_vendor
    from .safe_output_root import lexical_absolute, verify_directory_chain
    from .strict_json import strict_load, strict_loads
    from .worktree_identity import exact_worktree_identity
except ImportError:  # Direct script execution.
    from repository_input_contracts import (
        CURRENT_GOLDEN_VERSION,
        GOLDEN_NAMES,
        LEGACY_GOLDEN_VERSIONS,
        SCHEMA_NAMES,
    )
    from repository_input_files import (
        read_toml,
        required_repository_paths,
        safe_relative,
        sha256,
        validate_schema_document,
        verify_golden_set,
        verify_schema_set,
    )
    from repository_input_migrations import (
        verify_current_goldens,
        verify_legacy_migrations,
        verify_legacy_receipts,
    )
    from repository_input_vendor import verify_third_party, verify_vendor
    from safe_output_root import lexical_absolute, verify_directory_chain
    from strict_json import strict_load, strict_loads
    from worktree_identity import exact_worktree_identity

def verify_tracked(repo: Path, paths: tuple[str, ...]) -> None:
    top = subprocess.run(
        ["git", "-C", str(repo), "rev-parse", "--show-toplevel"],
        text=True, capture_output=True, check=False,
    )
    if top.returncode != 0 or Path(top.stdout.strip()).resolve() != repo.resolve():
        raise ValueError("repository input tracking requires the repository Git top-level")
    result = subprocess.run(
        ["git", "-C", str(repo), "ls-files", "--error-unmatch", "--", *paths],
        text=True, capture_output=True, check=False,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        raise ValueError(f"required repository input is not tracked: {detail}")


def verify_repository_inputs(repo: Path, require_tracked: bool = False) -> dict[str, object]:
    repo = lexical_absolute(repo)
    try:
        verify_directory_chain(repo)
    except ValueError as error:
        raise ValueError(
            "repository inputs require a canonical regular repository directory"
        ) from error
    if not repo.is_dir():
        raise ValueError("repository inputs require a canonical regular repository directory")
    required = required_repository_paths()
    for relative in required:
        path = repo / relative
        if path.is_symlink():
            raise ValueError(f"required repository input must not be a symlink: {relative}")
        if not path.is_file():
            raise ValueError(f"required repository input is missing: {relative}")
    verify_schema_set(repo)
    for version in LEGACY_GOLDEN_VERSIONS:
        verify_golden_set(repo, version)
    verify_golden_set(repo, CURRENT_GOLDEN_VERSION)
    verify_legacy_receipts(repo)
    licenses = verify_third_party(repo)
    vendor = verify_vendor(repo)
    repository_identity: dict[str, object] | None = None
    if require_tracked:
        tracked = list(required)
        tracked.extend(
            f"vendor/yjson_algorithms/{relative}"
            for relative in vendor["sourceSha256"].keys()
        )
        verify_tracked(repo, tuple(dict.fromkeys(tracked)))
        repository_identity = exact_worktree_identity(repo)
    return {
        "goldens": [
            f"tests/fixtures/golden-v{CURRENT_GOLDEN_VERSION}/{name}.docs.json"
            for name in GOLDEN_NAMES
        ],
        "legacyGoldens": [
            f"tests/fixtures/golden-v{version}/{name}.docs.json"
            for version in LEGACY_GOLDEN_VERSIONS for name in GOLDEN_NAMES
        ],
        "licenses": licenses,
        "vendor": vendor,
        "repositoryIdentity": repository_identity,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--require-tracked", action="store_true")
    parser.add_argument("--legacy-binary", type=Path)
    args = parser.parse_args()
    try:
        evidence = verify_repository_inputs(args.repo, require_tracked=args.require_tracked)
        if args.legacy_binary is not None:
            evidence["currentGoldenValidation"] = verify_current_goldens(
                args.repo.resolve(), args.legacy_binary
            )
            evidence["legacyMigrations"] = verify_legacy_migrations(
                args.repo.resolve(), args.legacy_binary
            )
    except (OSError, ValueError, tomllib.TOMLDecodeError, json.JSONDecodeError) as error:
        parser.error(str(error))
    print(
        f"repository inputs verified: {len(evidence['goldens'])} v8 goldens, "
        f"{len(evidence['legacyGoldens'])} frozen v6/v7 inputs, "
        f"{len(evidence['vendor']['sourceSha256'])} vendored sources"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
