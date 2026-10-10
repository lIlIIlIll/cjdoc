#!/usr/bin/env python3
"""Classify a pull-request diff into the CI jobs that must actually run.

Fail-safe rules:

* Any path that matches no known rule makes the whole run "full".
* An incomplete diff, an unparsable status line, `workflow_dispatch` or a `main`
  push makes the whole run "full".
* `tools/`, `docs/schema/`, `tests/fixtures/` and `site/` are never treated as
  documentation-only, because they feed native output or the generated site.

Classification only ever skips heavy jobs that are provably unrelated; it never
skips the aggregate `CI required` gate.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True

CHANGES_SCHEMA = "cjdoc.ci-changes/1"
ALL_JOBS = ("candidate-linux", "candidate-other", "docs-only")
# path prefix -> flags it turns on. Missing prefixes are `native`, so an
# unclassified path is impossible to overlook.
RULES: tuple[tuple[str, frozenset[str]], ...] = (
    # Schema sources are generated from the binary and are asserted by the CLI
    # stage, so they can never be treated as documentation-only.
    ("docs/schema/", frozenset({"native"})),
    ("docs/", frozenset({"docs"})),
    ("README.md", frozenset({"docs"})),
    ("site/", frozenset({"site", "native"})),
    ("examples/", frozenset({"site", "native"})),
    ("cjdoc.toml", frozenset({"site", "native"})),
    ("tests/showcase_contract/", frozenset({"site", "native"})),
)
PREFIX_ONLY_NATIVE = ("src/", "tests/", "tools/", "scripts/", "vendor/", ".github/")
FILES_ONLY_NATIVE = ("cjpm.toml", "cjpm.lock", "AGENTS.md")


def classify_paths(paths: list[str]) -> dict[str, bool]:
    native = site = docs = False
    for path in paths:
        rule = next((flags for prefix, flags in RULES if path == prefix or path.startswith(prefix)), None)
        if rule is None:
            if path.startswith(PREFIX_ONLY_NATIVE) or path in FILES_ONLY_NATIVE:
                rule = frozenset({"native"})
            else:
                raise LookupError(path)
        native = native or "native" in rule
        site = site or "site" in rule
        docs = docs or "docs" in rule
    jobs = {
        "candidate-linux": native or site,
        "candidate-other": native,
        "docs-only": docs and not (native or site),
    }
    return {"native": native, "site": site, "docs": docs, "jobSet": {name: jobs[name] for name in ALL_JOBS}}


def diff_paths(repo: Path, base: str, head: str) -> list[str]:
    completed = subprocess.run(
        ["git", "-C", str(repo), "diff", "--name-only", "--no-renames", f"{base}...{head}"],
        capture_output=True, text=True)
    if completed.returncode != 0:
        raise SystemExit(f"ci_changes.py: git diff failed: {completed.stderr.strip()}")
    return [line for line in completed.stdout.splitlines() if line]


def full_plan(reason: str) -> dict[str, object]:
    jobs = {name: True for name in ALL_JOBS}
    jobs["docs-only"] = False
    return {"schemaVersion": CHANGES_SCHEMA, "mode": "full", "reason": reason,
            "native": True, "site": True, "docs": True, "jobSet": jobs}


def plan_for(repo: Path, base: str, head: str, event: str, ref: str) -> dict[str, object]:
    if event == "workflow_dispatch":
        return full_plan("workflow_dispatch always runs the complete matrix")
    if event == "push" and ref.endswith("/main"):
        return full_plan("main pushes always run the complete matrix")
    try:
        paths = diff_paths(repo, base, head)
    except SystemExit as error:
        return full_plan(str(error))
    if not paths:
        return full_plan("empty or incomparable diff")
    try:
        classified = classify_paths(paths)
    except LookupError as error:
        return full_plan(f"unclassified path: {error}")
    return {"schemaVersion": CHANGES_SCHEMA, "mode": "classified", "reason": "matched",
            **classified, "paths": paths}


def write_github_output(path: Path, document: dict[str, object]) -> None:
    lines = [
        f"native={'true' if document['native'] else 'false'}",
        f"site={'true' if document['site'] else 'false'}",
        f"docs={'true' if document['docs'] else 'false'}",
        "plan=" + json.dumps(document, ensure_ascii=False, sort_keys=True, separators=(",", ":")),
    ]
    with path.open("a", encoding="utf-8", newline="\n") as stream:
        stream.write("\n".join(lines) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", required=True)
    parser.add_argument("--event", default="pull_request")
    parser.add_argument("--ref", default="")
    parser.add_argument("--out", type=Path, help="GitHub output file")
    parser.add_argument("--json", action="store_true", help="print the plan to stdout")
    args = parser.parse_args()
    document = plan_for(args.repo, args.base, args.head, args.event, args.ref)
    if args.out:
        write_github_output(args.out, document)
    if args.json or not args.out:
        print(json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
