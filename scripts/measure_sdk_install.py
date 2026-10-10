#!/usr/bin/env python3
"""Measure the two combined SDK-cache shapes under identical conditions.

Variant A (current default) caches the *extracted tree plus archives*; a warm hit
still re-authenticates by re-extracting both archives into a temporary directory.
Variant B caches only the two raw archives and extracts into a fresh directory
per job.

This script only measures. It never changes the default install behaviour: the
result is evidence for a separate, separately-reviewed change.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import statistics
import sys
import tempfile
import time
import zipfile

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))

from install_cangjie_sdk import (
    CACHE_ARCHIVE,
    STDX_CACHE_ARCHIVE,
    extract,
    sdk_root,
    stdx_root,
    tree_sha256,
    validate_combined_cache,
    verify_sha256,
)

MEASURE_SCHEMA = "cjdoc.sdk-install-measure/1"
VARIANTS = ("cache-extracted-and-archives", "cache-archives-only")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


class Clock:
    """Accumulate labelled wall-clock durations around each measured phase."""

    def __init__(self) -> None:
        self.durations: dict[str, float] = {}

    def measure(self, label: str):
        return _Measurement(self, label)

    def total(self) -> float:
        return sum(self.durations.values())


class _Measurement:
    def __init__(self, clock: Clock, label: str) -> None:
        self.clock = clock
        self.label = label

    def __enter__(self) -> None:
        self.started = time.perf_counter()

    def __exit__(self, *_exc) -> None:
        elapsed = (time.perf_counter() - self.started) * 1000
        self.clock.durations[self.label] = self.clock.durations.get(self.label, 0.0) + elapsed


def variant_a_warm(cache: Path, compiler_name: str, compiler_sha256: str,
                   stdx_name: str, stdx_sha256: str) -> dict:
    """Warm hit: validate the cached tree, which re-extracts both archives."""
    clock = Clock()
    with clock.measure("cacheRestoreMs"):
        pass  # the caller restored the cache directory before this measurement
    with clock.measure("validateMs"):
        sdk, stdx = validate_combined_cache(
            cache, compiler_name, compiler_sha256, stdx_name, stdx_sha256)
    return {"clock": clock, "sdkRoot": sdk.as_posix(), "stdxRoot": stdx.as_posix()}


def variant_b_warm(archive_dir: Path, compiler_name: str, compiler_sha256: str,
                   stdx_name: str, stdx_sha256: str) -> dict:
    """Warm hit: verify both archives, then extract into a fresh directory."""
    clock = Clock()
    with clock.measure("hashMs"):
        verify_sha256(archive_dir / compiler_name, compiler_sha256)
        verify_sha256(archive_dir / stdx_name, stdx_sha256)
    temporary = tempfile.TemporaryDirectory(prefix="cjdoc-sdk-measure-")
    fresh = Path(temporary.name) / "extracted"
    fresh.mkdir()
    with clock.measure("extractMs"):
        extract(archive_dir / compiler_name, fresh)
        extract(archive_dir / stdx_name, fresh)
    sdk, stdx = sdk_root(fresh), stdx_root(fresh)
    if sdk is None or stdx is None:
        raise SystemExit("measured archives do not contain both roots")
    result = {"clock": clock, "sdkRoot": sdk.as_posix(), "stdxRoot": stdx.as_posix(),
              "_temporary": temporary}
    return result


def identity(sdk: Path, stdx: Path) -> dict[str, object]:
    """The identity fields that must match between a cold and a warm install."""
    return {
        "compilerVersion": _compiler_version(sdk),
        "compilerTarget": _compiler_target(sdk),
        "stdxArtifacts": sorted(path.name for path in sorted(stdx.iterdir())
                                if path.is_file() and not path.is_symlink()),
        "stdxDigest": _directory_digest(stdx),
    }


def _compiler_version(sdk: Path) -> str:
    return _query(sdk, "Cangjie Compiler:")


def _compiler_target(sdk: Path) -> str:
    return _query(sdk, "Target:")


def _query(sdk: Path, label: str) -> str:
    import subprocess

    command = sdk / "bin" / "cjc"
    if not command.is_file():
        return ""
    try:
        completed = subprocess.run([str(command), "-v"], capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.SubprocessError):
        return ""
    for line in (completed.stdout + completed.stderr).splitlines():
        if line.startswith(label):
            return line.split(":", 1)[1].strip()
    return ""


def _directory_digest(root: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix()):
        relative = path.relative_to(root).as_posix()
        if path.is_symlink() or not path.is_file():
            continue
        digest.update(relative.encode("utf-8") + b"\0")
        digest.update(sha256_file(path).encode("ascii") + b"\0")
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--workdir", type=Path, required=True,
                        help="disk-backed scratch directory for the measurement")
    parser.add_argument("--compiler-archive", type=Path, required=True)
    parser.add_argument("--compiler-sha256", required=True)
    parser.add_argument("--compiler-name", default="cangjie-sdk.tar.gz")
    parser.add_argument("--stdx-archive", type=Path, required=True)
    parser.add_argument("--stdx-sha256", required=True)
    parser.add_argument("--stdx-name", default="cangjie-stdx.zip")
    parser.add_argument("--cycles", type=int, default=5,
                        help="successful warm samples required per variant")
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    if args.cycles < 5:
        parser.error("--cycles must be at least 5 for a reportable sample")

    work = args.workdir.resolve()
    work.mkdir(parents=True, exist_ok=True)
    # Variant A cache: extracted tree plus both archives, matching the default.
    cache_a = work / "variant-a"
    cache_a.mkdir(exist_ok=True)
    shutil.copyfile(args.compiler_archive, cache_a / CACHE_ARCHIVE)
    shutil.copyfile(args.stdx_archive, cache_a / STDX_CACHE_ARCHIVE)
    extract(cache_a / CACHE_ARCHIVE, cache_a)
    extract(cache_a / STDX_CACHE_ARCHIVE, cache_a)
    from install_cangjie_sdk import write_combined_cache_marker

    sdk_a, stdx_a = sdk_root(cache_a), stdx_root(cache_a)
    if sdk_a is None or stdx_a is None:
        raise SystemExit("variant A cache could not be prepared")
    write_combined_cache_marker(cache_a, sdk_a, stdx_a, args.compiler_name, args.compiler_sha256,
                                args.stdx_name, args.stdx_sha256,
                                _compiler_version(sdk_a), _compiler_target(sdk_a))
    # Variant B cache: only the two raw archives.
    cache_b = work / "variant-b"
    cache_b.mkdir(exist_ok=True)
    shutil.copyfile(args.compiler_archive, cache_b / args.compiler_name)
    shutil.copyfile(args.stdx_archive, cache_b / args.stdx_name)

    cold_identity = identity(sdk_a, stdx_a)
    samples: dict[str, list[dict]] = {name: [] for name in VARIANTS}
    failures: list[dict] = []
    for cycle in range(args.cycles):
        for variant in VARIANTS:
            try:
                with tempfile.TemporaryDirectory(dir=work, prefix="cycle-") as scratch:
                    started = time.perf_counter()
                    if variant == VARIANTS[0]:
                        outcome = variant_a_warm(cache_a, args.compiler_name, args.compiler_sha256,
                                                 args.stdx_name, args.stdx_sha256)
                    else:
                        outcome = variant_b_warm(cache_b, args.compiler_name, args.compiler_sha256,
                                                 args.stdx_name, args.stdx_sha256)
                    total = (time.perf_counter() - started) * 1000
                    observed = identity(Path(outcome["sdkRoot"]), Path(outcome["stdxRoot"]))
                    if observed != cold_identity:
                        raise SystemExit(f"{variant}: warm identity differs from the cold install")
                    samples[variant].append({"cycle": cycle, **outcome["clock"].durations,
                                             "totalMs": round(total, 3)})
            except Exception as error:  # noqa: BLE001 - recorded, never hidden
                failures.append({"variant": variant, "cycle": cycle, "error": str(error)})

    report = {
        "schemaVersion": MEASURE_SCHEMA,
        "cycles": args.cycles,
        "variants": {
            name: {"samples": samples[name],
                   "medianMs": round(statistics.median([item["totalMs"] for item in samples[name]]), 3)
                   if samples[name] else None}
            for name in VARIANTS
        },
        "failures": failures,
        "identityEqualUnderBothVariants": bool(all(samples.values())),
        "coldInstallIdentity": cold_identity,
        "note": "Measurement only; the default install path is unchanged by this run.",
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
                        encoding="utf-8", newline="\n")
    for name in VARIANTS:
        print(f"{name}: {len(samples[name])}/{args.cycles} paired samples, "
              f"median {report['variants'][name]['medianMs']} ms")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
