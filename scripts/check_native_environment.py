#!/usr/bin/env python3
"""Prove the native runner's degradation reporting, then run it outside the checkout.

Two controls, and the pair is what makes the tally meaningful:

* **Positive** -- the full unit suite with every prerequisite provisioned must
  report no degradation, from a working directory unrelated to the checkout and
  without any project path in the environment. Test fixtures resolve the checkout
  from the compiled binary, so the working directory cannot make a case pass.
* **Negative** -- the same wrapper invocation with the CHIR worker unset must report
  the selected fallback case as unverified. This runs the real `cjpm test` through
  `scripts/with_sts_cjpm.sh` and reads the wrapper's own tally, so a tally that can
  never fire is caught instead of a message this script prints about itself.

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
REFUSAL = "CJDOC_TEST_PLATFORM_REFUSAL "
SUMMARY = re.compile(r"PASSED: (\d+), SKIPPED: (\d+), ERROR: (\d+)")
TALLY = re.compile(r"Native test requirements — degraded: (\d+)")
WORKER_CASE = "extensionTargetsKeepPackageIdentityWhenNamesCollide"
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
    return int(matches[-1][0]), degradations, refusals


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
    for test in test_binaries(target):
        total, records, refused = run_tests(test, elsewhere, environment)
        passed += total
        degradations.extend(records)
        refusals.extend(refused)
    for record in degradations:
        print(record, file=sys.stderr)
    for record in refusals:
        print(record, file=sys.stderr)
    print(f"unrelated cwd: {passed} passed; degraded: {len(degradations)}; "
          f"platform refusals: {len(refusals)}")
    if passed <= 1:
        raise ValueError("the unrelated-cwd run did not exercise the native suite")
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


def qualify_wrapper(repo: Path, target: Path, elsewhere: Path) -> None:
    """The negative control, through the wrapper whose tally CI reads.

    The worker is removed, so the selected case takes its documented fallback. The
    wrapper must first report a non-zero degraded total attributed to that case, and
    then -- with strict verification on -- refuse the same run. A tally that cannot
    fire, or a strict gate that cannot fail, is caught here rather than in CI.
    """
    reporting = run_wrapper_control(repo, target, elsewhere, "CJDOC_TEST_REQUIRE_VERIFIED=0")
    tally = TALLY.search(reporting.stdout)
    if reporting.returncode != 0 or tally is None:
        print(reporting.stdout, end="", file=sys.stderr)
        raise ValueError("the wrapper did not report a degradation tally for the missing worker")
    total = int(tally.group(1))
    attributed = reporting.stdout.count(f"{DEGRADED}{WORKER_CASE}: ")
    print(f"missing worker: wrapper tally {total}; selected case records {attributed}")
    if total < 1 or attributed < 1:
        print(reporting.stdout, end="", file=sys.stderr)
        raise ValueError(f"the missing-worker control reported {total} degradation(s), "
                         f"{attributed} for {WORKER_CASE}")
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
