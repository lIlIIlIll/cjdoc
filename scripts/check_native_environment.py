#!/usr/bin/env python3
"""Prove the native runner's degradation reporting, then run it outside the checkout.

* The installed `cjpm test` with no worker and no wrapper must print the
  test process's own count, attributed to the two selected fallback cases.
* The strict wrapper must reject a real degradation. The same selected case
  is allowed to finish in reporting mode so both paths can be compared.
* The provisioned unit suite must run from an unrelated directory without a
  project-root environment variable or any degradation.

Usage: check_native_environment.py --repo REPO [--unit-target DIR]
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

DEGRADED = "CJDOC_TEST_DEGRADED "
# Keep the independently emitted count separate from individual records.
SUITE_TOTAL = re.compile(r"^CJDOC_TEST_DEGRADED_TOTAL (\d+)$", re.MULTILINE)
REFUSAL = "CJDOC_TEST_PLATFORM_REFUSAL "
SUMMARY = re.compile(r"PASSED: (\d+), SKIPPED: (\d+), ERROR: (\d+)")
TALLY = re.compile(r"Native test requirements — degraded: (\d+)")
WORKER_CASE = "extensionTargetsKeepPackageIdentityWhenNamesCollide"
RAW_WORKER_CASES = (WORKER_CASE, "chirSemanticFixtureUsesStructuredPackageRecords")
# Set by the wrapper for the run that consumes an already-built unit target.
REUSE_TARGET = "CJDOC_TEST_WRAPPER_UNIT_TARGET"


def executable(directory: Path, name: str) -> Path:
    path = directory / (name + (".exe" if os.name == "nt" else ""))
    if not path.is_file():
        raise ValueError(f"missing built executable: {name}")
    return path


def test_binaries(target: Path) -> list[Path]:
    """The main package and every `cjdoc.*` package executable the unit target holds.

    `std.testrunner` also lives in that directory and is a runner, not a suite, so the
    selection names the module's own binaries exactly as the module is named.
    """
    for directory in (target / "mock" / "release" / "unittest_bin",
                      target / "release" / "unittest_bin"):
        if not directory.is_dir():
            continue
        selected = [executable(directory, "cjdoc")]
        suffix = ".exe" if os.name == "nt" else ""
        selected += [path for path in sorted(directory.glob("cjdoc.*" + suffix))
                     if path.is_file() and os.access(path, os.X_OK)]
        return selected
    raise ValueError(f"no unittest_bin under {target}")


def run_tests(binary: Path, cwd: Path, env: dict[str, str], *flags: str):
    result = subprocess.run([str(binary), "--parallel=1", "--no-progress", "--no-color",
                             "--no-capture-output", *flags],
                            cwd=cwd, env=env, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True)
    matches = SUMMARY.findall(result.stdout)
    if result.returncode != 0 or not matches or any(int(row[2]) for row in matches):
        print(result.stdout, end="", file=sys.stderr)
        raise ValueError(f"standalone native tests failed: {binary.name}")
    degradations = [line for line in result.stdout.splitlines() if line.startswith(DEGRADED)]
    refusals = [line for line in result.stdout.splitlines() if line.startswith(REFUSAL)]
    # The suite's own count, not a count of these lines. Every process of a package
    # that owns the recorder prints its total, zero included; a package without the
    # recorder prints none, so absence is allowed here and the totals are checked
    # against the records once every binary has run.
    totals = [int(value) for value in SUITE_TOTAL.findall(result.stdout)]
    return int(matches[-1][0]), degradations, refusals, totals


def degrade_free_environment() -> dict[str, str]:
    """The host environment minus the project root the old wrapper injected.

    Removing it is the point: a fixture that still needed `CJDOC_TEST_ROOT` would
    fail here rather than look green because this script supplied it.
    """
    environment = dict(os.environ)
    environment.pop("CJDOC_TEST_ROOT", None)
    environment.pop("CJDOC_TEST_PROVE_MISSING_WORKER", None)
    return environment


def qualify_direct(repo: Path, target: Path, elsewhere: Path) -> None:
    """Every unit executable, run from an unrelated working directory."""
    worker = executable(repo / "target/release/bin", "chir-worker-main")
    environment = dict(degrade_free_environment(), CJDOC_CHIR_WORKER=str(worker))
    passed = 0
    degradations = []
    refusals = []
    reported = 0
    recorded_by_suite = 0
    for test in test_binaries(target):
        total, records, refused, totals = run_tests(test, elsewhere, environment)
        passed += total
        degradations.extend(records)
        refusals.extend(refused)
        reported += sum(totals)
        # Only the package that owns the recorder prints a total, so one binary per
        # run must report one and that count must cover every record in the run.
        if totals:
            recorded_by_suite += 1
    for record in degradations:
        print(record, file=sys.stderr)
    for record in refusals:
        print(record, file=sys.stderr)
    print(f"unrelated cwd: {passed} passed; degraded: {len(degradations)}; "
          f"suite reported: {reported} from {recorded_by_suite} binary(ies); "
          f"platform refusals: {len(refusals)}")
    if passed <= 1:
        raise ValueError("the unrelated-cwd run did not exercise the native suite")
    if recorded_by_suite < 1:
        raise ValueError("no native suite reported its own degradation count")
    if reported != len(degradations):
        raise ValueError(f"the suites reported {reported} degradation(s) "
                         f"but printed {len(degradations)} record(s)")
    if degradations:
        raise ValueError("the unrelated-cwd run left required behavior unverified")


def run_wrapper_control(repo: Path, target: Path, elsewhere: Path,
                        *extra: str) -> subprocess.CompletedProcess[str]:
    """One filtered case through the wrapper with the CHIR worker removed."""
    environment = degrade_free_environment()
    environment.pop("CJDOC_CHIR_WORKER", None)
    environment[REUSE_TARGET] = str(target)
    # Suppress the wrapper's own control so this run reports a tally instead of
    # starting a second control of itself.
    environment["CJDOC_TEST_MISSING_WORKER_CONTROL"] = "1"
    # The control is about the degradation tally, so the platform-refusal policy that
    # the full run applies must not decide this smaller run's outcome.
    environment["CJDOC_TEST_PLATFORM_REFUSALS"] = ""
    environment["RUNNER_TEMP"] = str(elsewhere)
    environment["GITHUB_WORKSPACE"] = str(repo)
    for assignment in extra:
        key, _, value = assignment.partition("=")
        environment[key] = value
    script = repo / "scripts" / "with_sts_cjpm.sh"
    return subprocess.run(
        ["bash", "-c", f'set -euo pipefail; . "$0"; cjpm test --skip-build --jobs 1 '
                       f'--parallel 1 --no-progress --no-capture-output --filter="*.{WORKER_CASE}"',
         str(script)],
        cwd=repo, env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)


def qualify_raw_cjpm(repo: Path, target: Path) -> None:
    """Run the SDK directly: the project test profile must expose passing output."""
    environment = degrade_free_environment()
    environment.pop("CJDOC_CHIR_WORKER", None)
    cjpm = environment.get("CJDOC_REAL_CJPM")
    if not cjpm:
        raise ValueError("CJDOC_REAL_CJPM must identify the installed SDK package manager")
    pattern = ",".join(f"*.{case}" for case in RAW_WORKER_CASES)
    result = subprocess.run(
        ["bash", "-c", 'exec "$CJDOC_REAL_CJPM" "$@"', "cjpm", "test",
         "--skip-build", "--target-dir", str(target), "--jobs", "1",
         "--parallel", "1", "--no-progress", "--no-color", f"--filter={pattern}"],
        cwd=repo, env=environment, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, text=True)
    totals = SUITE_TOTAL.findall(result.stdout)
    summary = SUMMARY.findall(result.stdout)
    reported = sum(map(int, totals))
    records = [line for line in result.stdout.splitlines() if line.startswith(DEGRADED)]
    expected = [f"{DEGRADED}{case}: missing CJDOC_CHIR_WORKER" for case in RAW_WORKER_CASES]
    if (result.returncode != 0 or not summary or int(summary[-1][0]) != len(expected)
            or reported != len(expected) or sorted(records) != sorted(expected)):
        print(result.stdout, end="", file=sys.stderr)
        raise ValueError("unwrapped cjpm test did not report the selected degradations")
    print(f"missing worker: unwrapped cjpm test — degraded: {reported}")


def qualify_wrapper(repo: Path, target: Path, elsewhere: Path) -> None:
    """The negative control, through the wrapper whose tally CI reads.

    Removing the worker makes the selected case take its documented fallback.
    The wrapper must report a non-zero count for the selected fallback case
    and refuse the same run when strict verification is enabled.
    """
    reporting = run_wrapper_control(repo, target, elsewhere, "CJDOC_TEST_REQUIRE_VERIFIED=0")
    tally = TALLY.search(reporting.stdout)
    if reporting.returncode != 0 or tally is None:
        print(reporting.stdout, end="", file=sys.stderr)
        raise ValueError("the wrapper did not report a degradation tally for the missing worker")
    total = int(tally.group(1))
    attributed = reporting.stdout.count(f"{DEGRADED}{WORKER_CASE}: ")
    suite_total = sum(map(int, SUITE_TOTAL.findall(reporting.stdout)))
    print(f"missing worker: wrapper tally {total}; selected case records {attributed}")
    if total < 1 or attributed < 1:
        print(reporting.stdout, end="", file=sys.stderr)
        raise ValueError(f"the missing-worker control reported {total} degradation(s), "
                         f"{attributed} for {WORKER_CASE}")
    if suite_total != total:
        print(reporting.stdout, end="", file=sys.stderr)
        raise ValueError(f"the suite counted {suite_total} degradation(s) but the log held {total}")
    strict = run_wrapper_control(repo, target, elsewhere, "CJDOC_TEST_REQUIRE_VERIFIED=1")
    strict_tally = TALLY.search(strict.stdout)
    if (strict.returncode != 1 or strict_tally is None or int(strict_tally.group(1)) != total
            or f"native suite left required behavior unverified: {total} degradation record(s)"
            not in strict.stdout):
        print(strict.stdout, end="", file=sys.stderr)
        raise ValueError("strict verification did not reject the same reported degradation")
    print("missing worker: strict verification rejected the same run")


def qualify_tests(repo: Path, target: Path) -> None:
    environment = os.environ
    if "RUNNER_TEMP" not in environment:
        raise ValueError("RUNNER_TEMP is required for the out-of-checkout run")
    with tempfile.TemporaryDirectory(prefix="cjdoc-test-cwd-", dir=environment["RUNNER_TEMP"]) as temporary:
        elsewhere = Path(temporary).resolve()
        qualify_raw_cjpm(repo, target)
        qualify_wrapper(repo, target, elsewhere)
        qualify_direct(repo, target, elsewhere)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--unit-target", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    repo = args.repo.resolve(strict=True)
    if args.unit_target is not None:
        qualify_tests(repo, args.unit_target.resolve(strict=True))
        return 0
    if "GITHUB_WORKSPACE" not in os.environ or "RUNNER_TEMP" not in os.environ:
        raise ValueError("the wrapper proof needs GITHUB_WORKSPACE and RUNNER_TEMP")
    return subprocess.run(
        ["bash", "-c", "exec cjpm test --jobs 1 --no-run"],
        cwd=repo,
        env=dict(os.environ, CJDOC_TEST_PROVE_ENVIRONMENT="1",
                 CJDOC_TEST_PROVE_MISSING_WORKER="1")).returncode


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        raise SystemExit(f"native environment: {error}") from error
