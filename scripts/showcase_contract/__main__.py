"""Resolve a plan, render cards, fingerprint a final tree, and gate publication."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sys
import tempfile

from .contract import ContractError, check_regressions, resolve_plan
from .evidence import validate_evidence
from .offline import create_archive
from .render import render_home
from .site import Site, load_json


def write_atomic(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink():
        raise ContractError(f"refusing to overwrite symlink: {path}")
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
            stream.write(content)
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="command", required=True)
    resolve = subcommands.add_parser("resolve", help="resolve targets before browser tests")
    resolve.add_argument("--plan", type=Path, required=True)
    resolve.add_argument("--site", type=Path, required=True)
    resolve.add_argument("--repository", type=Path, required=True)
    resolve.add_argument("--revision", required=True)
    resolve.add_argument("--template", type=Path, required=True)
    resolve.add_argument("--previous", type=Path)
    archive = subcommands.add_parser("archive", help="build the deterministic offline payload")
    archive.add_argument("--site", type=Path, required=True)
    digest = subcommands.add_parser("fingerprint", help="hash the entire final site")
    digest.add_argument("--site", type=Path, required=True)
    verify = subcommands.add_parser("verify", help="validate final links and browser evidence")
    verify.add_argument("--site", type=Path, required=True)
    verify.add_argument("--evidence", type=Path, required=True)
    verify.add_argument("--previous", type=Path)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        if args.command == "archive":
            print(create_archive(args.site))
            return 0
        site = Site(args.site)
        if args.command == "fingerprint":
            print(site.digest())
            return 0
        if args.command == "resolve":
            manifest = resolve_plan(load_json(args.plan), site, args.repository, args.revision)
            if args.previous:
                check_regressions(load_json(args.previous), manifest)
            homepage = render_home(args.template.read_text(encoding="utf-8"), manifest)
            manifest_text = json.dumps(manifest, ensure_ascii=False, sort_keys=True, indent=2,
                                       allow_nan=False) + "\n"
            # Render and resolve fully before mutating output. Browser tests run
            # after these writes, and verify performs no further site mutations.
            write_atomic(site.root / "showcase-features.json", manifest_text)
            write_atomic(site.root / "index.html", homepage)
            print("Targets resolved. Browser evidence is still required before publication.")
            return 0
        manifest = load_json(site.file("showcase-features.json"))
        if args.previous:
            check_regressions(load_json(args.previous), manifest)
        site.validate_links()
        validate_evidence(manifest, load_json(args.evidence), site, args.evidence.parent)
        print("Final-tree links and supplied browser evidence passed the showcase gate.")
        return 0
    except (ContractError, OSError, UnicodeError) as error:
        print(f"showcase contract: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
