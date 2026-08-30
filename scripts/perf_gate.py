#!/usr/bin/env python3
"""Fixed-CPU ABBA performance evidence and frozen-budget gate for cjdoc."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import statistics
import subprocess
import sys
import tempfile
from typing import Any


PROFILE_NAME = re.compile(r"^[a-z0-9][a-z0-9-]*$")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def atomic_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent,
                                     prefix=f".{path.name}.", delete=False) as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2, sort_keys=True)
        stream.write("\n")
        temporary = Path(stream.name)
    os.replace(temporary, path)


def resolve_binary(value: Path) -> Path:
    candidate = value.resolve()
    if candidate.is_file():
        return candidate
    executable = Path(f"{candidate}.exe")
    if executable.is_file():
        return executable
    raise ValueError(f"cjdoc binary does not exist: {candidate}")


def command_version(command: str) -> str | None:
    try:
        result = subprocess.run([command, "-v"], text=True, capture_output=True,
                                check=False, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return None
    text = (result.stdout or result.stderr).strip().splitlines()
    return text[0] if result.returncode == 0 and text else None


def fixed_cpu() -> int | None:
    if not hasattr(os, "sched_getaffinity"):
        return None
    allowed = os.sched_getaffinity(0)
    return min(allowed) if allowed else None


def affinity_preexec(cpu: int | None):
    if cpu is None or not hasattr(os, "sched_setaffinity"):
        return None

    def pin() -> None:
        os.sched_setaffinity(0, {cpu})

    return pin


def run_checked(command: list[str], cwd: Path, cpu: int | None) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(command, cwd=cwd, text=True, capture_output=True, check=False,
                            env={**os.environ, "PYTHONHASHSEED": "0"},
                            preexec_fn=affinity_preexec(cpu))
    if result.returncode != 0:
        raise RuntimeError(
            f"command failed ({result.returncode}): {' '.join(command)}\n"
            f"stdout:\n{result.stdout[-4000:]}\nstderr:\n{result.stderr[-4000:]}"
        )
    return result


def parse_profile(value: str, repo: Path) -> dict[str, Any]:
    if "=" not in value:
        raise ValueError("--profile must be NAME=PROJECT")
    name, raw_path = value.split("=", 1)
    if not PROFILE_NAME.fullmatch(name):
        raise ValueError(f"invalid profile name: {name!r}")
    project = Path(raw_path)
    if not project.is_absolute():
        project = repo / project
    project = project.resolve()
    if not (project / "cjpm.toml").is_file():
        raise ValueError(f"profile is not a cjpm project/workspace: {project}")
    stored = "." if project == repo else os.path.relpath(project, repo).replace(os.sep, "/")
    return {"name": name, "project": stored, "minDeclarations": 1,
            "resolvedProject": project}


def load_profiles(baseline: dict[str, Any], repo: Path) -> list[dict[str, Any]]:
    raw_profiles = baseline.get("profiles")
    if not isinstance(raw_profiles, list) or len(raw_profiles) < 2:
        raise ValueError("performance baseline must contain at least two profiles")
    result: list[dict[str, Any]] = []
    names: set[str] = set()
    for raw in raw_profiles:
        if not isinstance(raw, dict):
            raise ValueError("performance profile must be an object")
        name = raw.get("name")
        project_value = raw.get("project")
        minimum = raw.get("minDeclarations")
        if not isinstance(name, str) or not PROFILE_NAME.fullmatch(name) or name in names:
            raise ValueError("performance profile names must be unique safe identifiers")
        if not isinstance(project_value, str) or not isinstance(minimum, int) or minimum < 1:
            raise ValueError(f"invalid performance profile: {name}")
        project = (repo / project_value).resolve()
        if not (project / "cjpm.toml").is_file():
            raise ValueError(f"performance project is missing: {project_value}")
        names.add(name)
        result.append({**raw, "resolvedProject": project})
    return result


def read_measurement(stdout: str) -> dict[str, int | None]:
    lines = [line for line in stdout.splitlines() if line.strip()]
    if not lines:
        raise ValueError("measure_command.py produced no result")
    value = json.loads(lines[-1])
    elapsed = value.get("elapsedMs")
    rss = value.get("peakRssKiB")
    if not isinstance(elapsed, int) or elapsed < 0:
        raise ValueError("invalid elapsedMs measurement")
    if rss is not None and (not isinstance(rss, int) or rss < 0):
        raise ValueError("invalid peakRssKiB measurement")
    return {"elapsedMs": elapsed, "peakRssKiB": rss}


def validate_document(path: Path, minimum: int) -> str:
    document = json.loads(path.read_text(encoding="utf-8"))
    declarations = document.get("declarations")
    diagnostics = document.get("diagnostics")
    if document.get("schemaVersion") != "cjdoc.doc-ir/7":
        raise ValueError("performance run emitted non-v7 Doc IR")
    if not isinstance(declarations, list) or len(declarations) < minimum:
        raise ValueError("performance run did not meet its declaration floor")
    if not isinstance(diagnostics, list) or any(
        isinstance(item, dict) and item.get("severity") == "error" for item in diagnostics
    ):
        raise ValueError("performance run emitted error diagnostics")
    return sha256(path)


def measure_profiles(binary: Path, profiles: list[dict[str, Any]], cycles: int,
                     repo: Path, work: Path, cpu: int | None) -> list[dict[str, Any]]:
    if cycles < 1 or cycles > 10:
        raise ValueError("cycles must be between 1 and 10")
    results: list[dict[str, Any]] = []
    measure = repo / "scripts/measure_command.py"
    for profile in profiles:
        name = profile["name"]
        project = profile["resolvedProject"]
        minimum = profile["minDeclarations"]
        profile_root = work / name
        cache = profile_root / "warm-cache"
        prewarm = profile_root / "prewarm"
        run_checked([
            str(binary), "generate", "--project", str(project), "--format", "json",
            "--output", str(prewarm), "--cache-dir", str(cache), "--jobs", "1",
        ], repo, cpu)
        reference_checksum = validate_document(prewarm / "docs.json", minimum)
        variants: dict[str, list[dict[str, int | None]]] = {"cold": [], "warm": []}
        order = ["cold", "warm", "warm", "cold"] * cycles
        for run_index, variant in enumerate(order):
            output = profile_root / f"run-{run_index:02d}-{variant}"
            command = [
                sys.executable, str(measure), str(binary), "generate",
                "--project", str(project), "--format", "json", "--output", str(output),
                "--jobs", "1",
            ]
            if variant == "cold":
                command.append("--no-cache")
            else:
                command.extend(["--cache-dir", str(cache)])
            measured = read_measurement(run_checked(command, repo, cpu).stdout)
            checksum = validate_document(output / "docs.json", minimum)
            if checksum != reference_checksum:
                raise ValueError(f"{name}/{variant} output checksum changed across ABBA runs")
            variants[variant].append(measured)

        summary: dict[str, Any] = {
            "name": name,
            "project": profile["project"],
            "minDeclarations": minimum,
            "docsSha256": reference_checksum,
            "variants": {},
        }
        for variant, samples in variants.items():
            elapsed = [sample["elapsedMs"] for sample in samples]
            rss = [sample["peakRssKiB"] for sample in samples
                   if sample["peakRssKiB"] is not None]
            summary["variants"][variant] = {
                "samples": samples,
                "medianElapsedMs": round(statistics.median(elapsed)),
                "maxElapsedMs": max(elapsed),
                "medianPeakRssKiB": round(statistics.median(rss)) if rss else None,
                "maxPeakRssKiB": max(rss) if rss else None,
            }
        results.append(summary)
    return results


def baseline_from_results(results: list[dict[str, Any]], cycles: int,
                          cpu: int | None) -> dict[str, Any]:
    profiles: list[dict[str, Any]] = []
    for result in results:
        variants: dict[str, Any] = {}
        for name, measured in result["variants"].items():
            elapsed_limit = max(1000, math.ceil(measured["maxElapsedMs"] * 3.0))
            rss_value = measured["maxPeakRssKiB"]
            variants[name] = {
                "baselineMedianElapsedMs": measured["medianElapsedMs"],
                "baselineMedianPeakRssKiB": measured["medianPeakRssKiB"],
                "maxElapsedMs": elapsed_limit,
                "maxPeakRssKiB": None if rss_value is None else math.ceil(rss_value * 2.0),
            }
        profiles.append({
            "name": result["name"],
            "project": result["project"],
            "minDeclarations": result["minDeclarations"],
            "referenceDocsSha256": result["docsSha256"],
            "variants": variants,
        })
    return {
        "schemaVersion": "cjdoc.perf-baseline/1",
        "state": "candidate",
        "method": "fixed-cpu cold/warm ABBA; fresh output per sample; SHA-256 identity",
        "cycles": cycles,
        "referenceEnvironment": {
            "platform": platform.platform(),
            "python": platform.python_version(),
            "cjc": command_version("cjc"),
            "cjpm": command_version("cjpm"),
            "fixedCpu": cpu,
        },
        "profiles": profiles,
    }


def verify_limits(baseline: dict[str, Any], results: list[dict[str, Any]]) -> None:
    expected = {profile["name"]: profile for profile in baseline["profiles"]}
    failures: list[str] = []
    for result in results:
        profile = expected[result["name"]]
        reference_checksum = profile.get("referenceDocsSha256")
        if not isinstance(reference_checksum, str) or not re.fullmatch(r"[0-9a-f]{64}", reference_checksum):
            failures.append(f"{result['name']}: invalid reference Doc IR checksum")
        elif result.get("docsSha256") != reference_checksum:
            failures.append(
                f"{result['name']}: Doc IR checksum {result.get('docsSha256')} != {reference_checksum}"
            )
        for variant, measured in result["variants"].items():
            limits = profile.get("variants", {}).get(variant)
            if not isinstance(limits, dict):
                failures.append(f"{result['name']}/{variant}: missing limits")
                continue
            elapsed_limit = limits.get("maxElapsedMs")
            rss_limit = limits.get("maxPeakRssKiB")
            if not isinstance(elapsed_limit, int) or elapsed_limit < 1:
                failures.append(f"{result['name']}/{variant}: invalid elapsed limit")
            elif measured["maxElapsedMs"] > elapsed_limit:
                failures.append(
                    f"{result['name']}/{variant}: elapsed {measured['maxElapsedMs']} > {elapsed_limit} ms"
                )
            measured_rss = measured["maxPeakRssKiB"]
            if rss_limit is not None:
                if not isinstance(rss_limit, int) or rss_limit < 1:
                    failures.append(f"{result['name']}/{variant}: invalid RSS limit")
                elif measured_rss is None:
                    failures.append(f"{result['name']}/{variant}: RSS is unavailable")
                elif measured_rss > rss_limit:
                    failures.append(
                        f"{result['name']}/{variant}: RSS {measured_rss} > {rss_limit} KiB"
                    )
    if failures:
        raise ValueError("performance gate failed:\n" + "\n".join(failures))


def main() -> int:
    repo = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    record = subparsers.add_parser("record")
    record.add_argument("--binary", type=Path, default=repo / "target/release/bin/main")
    record.add_argument("--profile", action="append", required=True)
    record.add_argument("--cycles", type=int, default=1)
    record.add_argument("--output", type=Path, required=True)
    record.add_argument("--evidence", type=Path)

    check = subparsers.add_parser("check")
    check.add_argument("--binary", type=Path, default=repo / "target/release/bin/main")
    check.add_argument("--baseline", type=Path, default=repo / "tests/perf/baseline.json")
    check.add_argument("--evidence", type=Path,
                       default=repo / "target/release-evidence/performance.json")
    check.add_argument("--allow-candidate", action="store_true")

    args = parser.parse_args()
    try:
        binary = resolve_binary(args.binary)
        cpu = fixed_cpu()
        if platform.system() == "Linux" and cpu is None:
            raise ValueError("Linux performance gate could not select a fixed CPU")
        if args.command == "record":
            profiles = [parse_profile(value, repo) for value in args.profile]
            if len(profiles) < 2:
                raise ValueError("record requires at least two profiles")
            cycles = args.cycles
            evidence_path = (args.evidence or args.output.with_suffix(".evidence.json")).resolve()
            baseline = None
        else:
            baseline = json.loads(args.baseline.resolve().read_text(encoding="utf-8"))
            if baseline.get("schemaVersion") != "cjdoc.perf-baseline/1":
                raise ValueError("unknown performance baseline schema")
            if baseline.get("state") != "frozen" and not args.allow_candidate:
                raise ValueError("performance baseline is not frozen")
            cycles = baseline.get("cycles")
            if not isinstance(cycles, int):
                raise ValueError("baseline cycles must be an integer")
            profiles = load_profiles(baseline, repo)
            evidence_path = args.evidence.resolve()

        evidence_path.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="performance-", dir=evidence_path.parent) as temporary:
            results = measure_profiles(binary, profiles, cycles, repo, Path(temporary), cpu)
        evidence = {
            "schemaVersion": "cjdoc.perf-evidence/1",
            "binarySha256": sha256(binary),
            "platform": platform.platform(),
            "fixedCpu": cpu,
            "cycles": cycles,
            "profiles": results,
        }
        atomic_json(evidence_path, evidence)
        if args.command == "record":
            atomic_json(args.output.resolve(), baseline_from_results(results, cycles, cpu))
        else:
            verify_limits(baseline, results)
        print(json.dumps(evidence, ensure_ascii=False, sort_keys=True))
        return 0
    except (OSError, ValueError, RuntimeError, json.JSONDecodeError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    raise SystemExit(main())
