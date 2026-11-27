#!/usr/bin/env python3
"""Prove missing-worker reporting and run the same native tests outside the checkout."""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

DEGRADED = "CJDOC_TEST_DEGRADED "
SUMMARY = re.compile(r"PASSED: (\d+), SKIPPED: (\d+), ERROR: (\d+)")
WORKER_CASE = "extensionTargetsKeepPackageIdentityWhenNamesCollide"


def executable(directory: Path, name: str) -> Path:
    path = directory / (name + (".exe" if os.name == "nt" else ""))
    if not path.is_file():
        raise ValueError(f"missing built executable: {name}")
    return path


def run_tests(binary: Path, cwd: Path, env: dict[str, str], *flags: str):
    result = subprocess.run([str(binary), "--parallel=1", "--no-color", "--no-capture-output", *flags],
                            cwd=cwd, env=env, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True)
    matches = SUMMARY.findall(result.stdout)
    if result.returncode != 0 or not matches or any(int(row[2]) for row in matches):
        print(result.stdout, end="", file=sys.stderr)
        raise ValueError(f"standalone native tests failed: {binary.name}")
    degradations = [line for line in result.stdout.splitlines() if line.startswith(DEGRADED)]
    return int(matches[-1][0]), degradations


def qualify_tests(repo: Path, target: Path) -> None:
    test_dir = target / "release" / "unittest_bin"
    main = executable(test_dir, "cjdoc")
    worker = executable(repo / "target/release/bin", "chir-worker-main")
    env = dict(os.environ, CJDOC_TEST_ROOT=str(repo), CJDOC_CHIR_WORKER=str(worker))
    without_worker = {key: value for key, value in env.items() if key != "CJDOC_CHIR_WORKER"}
    env_suffix = ".exe" if os.name == "nt" else ""
    packages = [path for path in sorted(test_dir.glob("cjdoc.*" + env_suffix))
                if path.is_file() and os.access(path, os.X_OK)]
    with tempfile.TemporaryDirectory(prefix="cjdoc-test-cwd-", dir=os.environ["RUNNER_TEMP"]) as temporary:
        elsewhere = Path(temporary).resolve()
        count, markers = run_tests(main, elsewhere, without_worker, f"--filter=*{WORKER_CASE}*")
        expected = f"{DEGRADED}{WORKER_CASE}: missing CJDOC_CHIR_WORKER"
        if count != 1 or markers != [expected]:
            raise ValueError(f"missing-worker control: expected one passing fallback and its degradation, got {count}, {markers}")
        print(f"missing worker: degraded: {len(markers)}")
        passed = 0
        degraded = []
        for test in [main, *packages]:
            total, records = run_tests(test, elsewhere, env)
            passed += total
            degraded.extend(records)
        # This positive control targets the fully provisioned Linux acceptance
        # host. Other platforms report their actual prerequisites in normal tests.
        for record in degraded:
            print(record, file=sys.stderr)
        print(f"unrelated cwd: {passed} passed; degraded: {len(degraded)}")
        if not packages or passed <= 1 or degraded:
            raise ValueError("the unrelated-cwd run did not exercise the full native suite without degradation")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--unit-target", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    repo = args.repo.resolve(strict=True)
    if args.unit_target is not None:
        qualify_tests(repo, args.unit_target.resolve(strict=True))
        return 0
    return subprocess.run(["bash", "-c", "exec cjpm test --jobs 1 --no-run"], cwd=repo,
                          env=dict(os.environ, CJDOC_TEST_PROVE_ENVIRONMENT="1")).returncode


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        raise SystemExit(f"native environment: {error}") from error
