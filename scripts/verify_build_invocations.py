#!/usr/bin/env python3
"""Verify the build that produced the packaged release binary (issue CI-08.3).

The workflow's text can only say what was *written*. This reads the record the STS
wrapper writes as it runs, so the comparison covers the commands that were really
executed, including a build routed around the literal `cjpm build` spelling.

The acceptance gates legitimately rebuild through the wrapper, so several builds may
be recorded. What is required is stricter and still simple:

* **every** recorded build must have run under the pinned option — a single build
  with different parameters fails the release, wherever it came from;
* at least one build must have run;
* the packaged binary's digest must equal the digest of the **last** recorded build,
  so a later build that replaced it is detected even though it was recorded.

Usage: verify_build_invocations.py --log FILE --binary PATH [--since OFFSET]
                                   [--expect-compile-option -O1]
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True

SCHEMA = "cjdoc.sts-invocation/1"
CHUNK = 1 << 20


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(CHUNK):
            value.update(chunk)
    return value.hexdigest()


def read_since(log: Path, offset: int) -> list[dict]:
    if not log.is_file():
        raise SystemExit(f"build invocations: no invocation log at {log}")
    data = log.read_bytes()
    if offset > len(data):
        raise SystemExit(
            f"build invocations: the log shrank below the recorded offset ({offset}), so "
            "the invocations cannot be attributed")
    records = []
    for line in data[offset:].decode("utf-8").splitlines():
        if not line.strip():
            continue
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError as error:
            raise SystemExit(f"build invocations: malformed log line {line!r}: {error}")
    return records


def verify(records: list[dict], expected_option: str, binary: Path | None) -> dict[str, object]:
    if not records:
        raise SystemExit(
            "build invocations: the build performed no `cjpm` invocation, so the release "
            "evidence cannot be attributed to a build (CI-08.3)")
    builds = [record for record in records if record.get("argv", [None])[:1] == ["build"]]
    if not builds:
        raise SystemExit(
            "build invocations: no `cjpm build` was performed through the wrapper, so the "
            "packaged binary has no recorded parameters (CI-08.3)")
    for build in builds:
        if build.get("schemaVersion") != SCHEMA:
            raise SystemExit(f"build invocations: unexpected record {build!r} (CI-08.3)")
        # A single build under other parameters is enough to invalidate the release,
        # whichever step ran it.
        if build.get("option") != expected_option:
            raise SystemExit(
                f"build invocations: a build ran with override-compile-option="
                f"{build.get('option')!r}, not the required {expected_option!r} (CI-08.3)")
    last = builds[-1]
    if binary is not None:
        # Binding the packaged artefact to the last recorded build closes the gap a
        # later, unrecorded build would leave.
        recorded = last.get("binary")
        if not isinstance(recorded, dict):
            raise SystemExit(
                "build invocations: the build recorded no produced binary, so the "
                "packaged artefact cannot be bound to it (CI-08.3)")
        if not binary.is_file():
            raise SystemExit(f"build invocations: no binary at {binary} (CI-08.3)")
        if (binary.stat().st_size != recorded.get("size")
                or digest(binary) != recorded.get("sha256")):
            raise SystemExit(
                "build invocations: the binary on disk is not the one the last recorded "
                "build produced, so another build replaced it (CI-08.3)")
    return {
        "schemaVersion": "cjdoc.build-invocations/1",
        "invocations": len(records),
        "builds": len(builds),
        "argv": last["argv"],
        "option": last["option"],
        "package": last.get("package"),
        "binarySha256": (last.get("binary") or {}).get("sha256") if last.get("binary") else None,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--since", type=int, default=0)
    parser.add_argument("--expect-compile-option", default="-O1")
    parser.add_argument("--binary", type=Path)
    args = parser.parse_args()
    result = verify(read_since(args.log, args.since), args.expect_compile_option, args.binary)
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
