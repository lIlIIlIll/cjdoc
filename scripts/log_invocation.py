#!/usr/bin/env python3
"""Record one `cjpm` invocation performed through the STS wrapper.

Appends a JSON line per build/test/run, including the digest of the binary that
build produced. CI-08.3 reads this record instead of parsing the workflow's text, so
what is compared is what the wrapper actually ran and produced: a build routed
around `cjpm build` leaves no record, and a later build that overwrote the binary
changes the digest the packaged artefact must match.

Usage: log_invocation.py --log FILE --manifest FILE --option OPTION [--binary PATH] -- ARGS...
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import sys

sys.dont_write_bytecode = True

SCHEMA = "cjdoc.sts-invocation/1"
CHUNK = 1 << 20


def binary_digest(path: Path) -> dict[str, object] | None:
    """The digest and size of the produced binary, or None when it is absent."""
    if not path.is_file():
        return None
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(CHUNK):
            digest.update(chunk)
    return {"sha256": digest.hexdigest(), "size": path.stat().st_size}


def append(log: Path, record: dict) -> None:
    log.parent.mkdir(parents=True, exist_ok=True)
    # Append is atomic enough at this size and keeps concurrent shards from
    # clobbering each other's records.
    with log.open("a", encoding="utf-8", newline="\n") as stream:
        stream.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True,
                        help="the manifest being built; its package name is recorded")
    parser.add_argument("--option", required=True)
    parser.add_argument("--binary", type=Path)
    parser.add_argument("args", nargs=argparse.REMAINDER)
    ns = parser.parse_args()
    argv = [arg for arg in ns.args if arg != "--"]
    binary = None
    if ns.binary is not None:
        binary = binary_digest(ns.binary)
        # A `build` that produced no binary cannot be the release's build; recording
        # the absence lets the check refuse rather than assume.
    # Read the package from the manifest, not from the caller: the wrapper patches
    # the workspace manifest but may be invoked from an auxiliary project, and
    # mislabelling that build would let it slip past the argument comparison.
    import tomllib
    package = tomllib.loads(ns.manifest.read_text(encoding="utf-8")).get("package", {})
    append(ns.log, {
        "schemaVersion": SCHEMA,
        "package": package.get("name", ""),
        "option": ns.option,
        "argv": argv,
        "binary": binary,
        "platform": os.environ.get("RUNNER_OS", ""),
        "workspace": os.environ.get("GITHUB_WORKSPACE", ""),
    })
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
