#!/usr/bin/env python3
"""Verify the build the release candidate actually performed (issue CI-08.3).

The workflow's text can only say what was *written*. This reads the record the STS
wrapper writes as it runs, so the comparison covers the command that was really
executed, including a build routed around the literal `cjpm build` spelling.

The candidate job snapshots the log before its build line and passes the delta
afterwards; exactly one `cjpm build` must have run, under the pinned option.

Usage: verify_build_invocations.py --log FILE --since OFFSET [--binary PATH]
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


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1 << 20):
            value.update(chunk)
    return value.hexdigest()


def verify(records: list[dict], expected_option: str,
           binary: Path | None = None) -> dict[str, object]:
    if not records:
        raise SystemExit(
            "build invocations: the build line performed no `cjpm` invocation, so the "
            "release evidence cannot be attributed to a build (CI-08.3)")
    builds = [record for record in records
              if record.get("argv", [None])[:1] == ["build"]]
    if len(builds) != 1:
        raise SystemExit(
            f"build invocations: the build line ran {len(builds)} `cjpm build` "
            "invocations, so the parameters of the packaged binary are ambiguous "
            "(CI-08.3)")
    build = builds[0]
    if build.get("schemaVersion") != SCHEMA:
        raise SystemExit(f"build invocations: unexpected record {build!r} (CI-08.3)")
    if build.get("option") != expected_option:
        raise SystemExit(
            f"build invocations: the build ran with override-compile-option="
            f"{build.get('option')!r}, not the required {expected_option!r} (CI-08.3)")
    if binary is not None:
        # Binding the packaged binary to the build that recorded it closes the gap a
        # second, unrecorded build would leave: the file on disk must be the one this
        # invocation produced.
        recorded = build.get("binary")
        if not isinstance(recorded, dict):
            raise SystemExit(
                "build invocations: the build recorded no produced binary, so the "
                "packaged artefact cannot be bound to it (CI-08.3)")
        if not binary.is_file():
            raise SystemExit(f"build invocations: no binary at {binary} (CI-08.3)")
        if binary.stat().st_size != recorded.get("size") or digest(binary) != recorded.get("sha256"):
            raise SystemExit(
                "build invocations: the binary on disk is not the one the recorded build "
                "produced, so another build replaced it (CI-08.3)")
    return {
        "schemaVersion": "cjdoc.build-invocations/1",
        "invocations": len(records),
        "builds": len(builds),
        "argv": build["argv"],
        "option": build["option"],
        "package": build.get("package"),
        "binarySha256": (build.get("binary") or {}).get("sha256") if build.get("binary") else None,
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
