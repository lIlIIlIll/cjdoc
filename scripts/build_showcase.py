#!/usr/bin/env python3
"""Build the bilingual showcase from native, reproducible PocketKit outputs.

This assembles and statically validates the final payload. The separate browser
runner and evidence verifier are required before publication.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True

from showcase_build.integration import build, install_output
from showcase_contract.site import ContractError
from safe_output_root import lexical_absolute, verify_directory_chain
from worktree_identity import exact_worktree_identity


def resolve_revision(repo: Path, requested: str | None) -> str:
    if requested:
        return requested
    if os.environ.get("GITHUB_SHA"):
        return os.environ["GITHUB_SHA"]
    result = subprocess.run(["git", "rev-parse", "HEAD"], cwd=repo, check=True,
                            capture_output=True, text=True)
    return result.stdout.strip()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--project", type=Path, default=Path("."))
    parser.add_argument("--repository-url")
    parser.add_argument("--revision")
    parser.add_argument("--previous", type=Path, help="reviewed feature manifest for regression checks")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    binary, project = [(repo / path).resolve() for path in (args.binary, args.project)]
    output = lexical_absolute(repo / args.output)
    if output == repo or repo.is_relative_to(output) or project.is_relative_to(output) or binary.is_relative_to(output):
        raise ContractError("output must be separate from source and the native binary")
    if (repo / args.output).is_symlink():
        raise ContractError("output must not be a symlink")
    verify_directory_chain(output.parent, create=True)
    repository = args.repository_url or (os.environ.get("GITHUB_SERVER_URL", "https://github.com") +
                                         "/" + os.environ.get("GITHUB_REPOSITORY", "lIlIIlIll/cjdoc"))
    provenance = {"repository": repository, "revision": resolve_revision(repo, args.revision)}
    exact_worktree_identity(repo, provenance["revision"])
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="cjdoc-showcase-", dir=output.parent) as temporary:
        work = Path(temporary)
        staged = work / "site"
        build(repo, binary, project, staged, work, provenance, args.previous)
        exact_worktree_identity(repo, provenance["revision"])
        install_output(staged, output)
    print(f"showcase built at {output}; final-tree browser acceptance is still required")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"showcase build failed: {error}", file=sys.stderr)
        raise SystemExit(1)
