#!/usr/bin/env python3
"""Record machine-readable CI stage timings, identity and bounded stage logs.

Library use:

    records: list[dict] = []
    with stage("cli", ["bash", "scripts/check.sh", "cli"], kind="cli", records=records) as handle:
        handle.record({"goldens": 9})
    write_stage_evidence(path, records)

CLI use:

    python scripts/ci_stage.py run --id cli --kind cli --evidence DIR -- <command...>
    python scripts/ci_stage.py summarize --evidence DIR --output SUMMARY.md
    python scripts/ci_stage.py wallclock --run RUN_ID --attempt 1
    python scripts/ci_stage.py verify-identity --manifest PATH [--main-binary PATH]
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import platform as machine
import re
import signal
import subprocess
import sys
import threading
import time

STAGE_SCHEMA = "cjdoc.ci-stage/1"
WALLCLOCK_SCHEMA = "cjdoc.ci-wallclock/1"
BUILD_MANIFEST_SCHEMA = "cjdoc.ci-build-manifest/1"
STAGE_KINDS = frozenset({
    "build", "native", "python", "cli", "provider", "smoke", "site-assemble",
    "browser-shard", "reading", "source-reproduction", "merge", "package",
    "publish", "sdk",
})
STAGES_FILE = "stages.json"
_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_RECORDS: list[dict] = []
_COMPILE_OPTIONS = ("--jobs 1", "-O1")


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def git_value(repo: Path, *args: str) -> str:
    completed = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True)
    return completed.stdout.strip() if completed.returncode == 0 else ""


def runtime_platform() -> tuple[str, str]:
    system, release = machine.system().lower(), machine.machine().lower()
    architecture = {"x86_64": "x64", "amd64": "x64", "aarch64": "arm64", "arm64": "arm64"}.get(
        release, release or "unknown")
    if system == "linux":
        return f"linux-{architecture}", "Linux"
    if system == "darwin":
        return f"macos-{architecture}", "macOS"
    if system == "windows":
        return f"windows-{architecture}", "Windows"
    return f"{system or 'unknown'}-{architecture}", machine.system() or "unknown"


def parse_cache(value: str | None) -> dict[str, str]:
    parsed: dict[str, str] = {}
    for item in (value or "").split(","):
        item = item.strip()
        if not item:
            continue
        name, _, state = item.partition("=")
        if state not in {"hit", "miss", "unknown"}:
            raise SystemExit(f"ci_stage.py: invalid cache state for {name!r}: {state!r}")
        parsed[name.strip()] = state
    return parsed


def stage_environment(repo: Path | None = None) -> dict[str, object]:
    """Identity fields that must stay stable across producers and consumers."""
    repo = Path(repo or os.environ.get("CJDOC_REPO", ".")).resolve()
    platform_id, os_name = runtime_platform()
    compile_options = list(_COMPILE_OPTIONS) if os.environ.get("CJDOC_REAL_CJPM") else []
    return {
        "checkoutCommit": os.environ.get("GITHUB_SHA") or git_value(repo, "rev-parse", "HEAD"),
        "checkoutTree": git_value(repo, "rev-parse", "HEAD^{tree}"),
        "platform": platform_id,
        "os": os_name,
        "architecture": machine.machine(),
        "runnerImage": "-".join(
            part for part in (os.environ.get("ImageOS"), os.environ.get("ImageVersion")) if part),
        "sdkVersion": os.environ.get("CJDOC_TOOLCHAIN_VERSION") or os.environ.get("CANGJIE_SDK_VERSION", ""),
        "stdxDigest": os.environ.get("CJDOC_STDX_DIGEST", ""),
        "toolchainFingerprint": os.environ.get("CJDOC_TOOLCHAIN_FINGERPRINT", ""),
        "toolchainTarget": os.environ.get("CJDOC_TOOLCHAIN_TARGET", ""),
        "compileOptions": compile_options,
        "cache": parse_cache(os.environ.get("CJDOC_CACHE_STATE")),
        "runId": os.environ.get("GITHUB_RUN_ID", ""),
        "runAttempt": int(os.environ.get("GITHUB_RUN_ATTEMPT", "0") or 0),
        "job": os.environ.get("GITHUB_JOB", ""),
    }


class StageHandle:
    """Mutable per-stage record; `record()` merges extra evidence into it."""

    def __init__(self, stage_id: str, kind: str, command: list[str]) -> None:
        self.record_value: dict[str, object] = {
            "stageId": stage_id,
            "kind": kind,
            "command": list(command),
            "timingSource": "monotonic",
        }

    def record(self, extra: dict[str, object] | None = None) -> dict[str, object]:
        if extra:
            overlap = set(extra) & set(self.record_value)
            if overlap:
                raise SystemExit(f"ci_stage.py: stage evidence overwrites fields: {sorted(overlap)}")
            self.record_value.update(extra)
        return self.record_value


@contextmanager
def stage(stage_id: str, command: list[str], *, kind: str,
          records: list[dict] | None = None, repo: Path | None = None):
    """Time a Python-level stage and append its record on exit (or failure)."""
    target = _RECORDS if records is None else records
    if kind not in STAGE_KINDS:
        raise SystemExit(f"ci_stage.py: unknown stage kind: {kind}")
    handle = StageHandle(stage_id, kind, command)
    started = time.perf_counter()
    handle.record_value["startedAt"] = utc_now()
    try:
        yield handle
    except BaseException:
        handle.record_value.update({"wallMs": round((time.perf_counter() - started) * 1000, 3),
                                    "exitCode": 1, "status": "failed"})
        target.append(handle.record_value)
        raise
    handle.record_value.update({
        "wallMs": round((time.perf_counter() - started) * 1000, 3),
        "exitCode": 0,
        "status": "passed",
        "environment": stage_environment(repo),
    })
    target.append(handle.record_value)
    return


def merge_records(existing: list[dict], incoming: list[dict]) -> list[dict]:
    seen = {(item.get("stageId"), item.get("startedAt")) for item in existing}
    merged = list(existing)
    for item in incoming:
        key = (item.get("stageId"), item.get("startedAt"))
        if key not in seen:
            seen.add(key)
            merged.append(item)
    return merged


def write_stage_evidence(path: Path, records: list[dict]) -> None:
    """Atomically append records; existing unrelated records are preserved."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    existing: list[dict] = []
    if path.exists():
        try:
            loaded = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            raise SystemExit(f"ci_stage.py: cannot read existing evidence: {path}")
        if isinstance(loaded, dict) and isinstance(loaded.get("stages"), list):
            existing = loaded["stages"]
    document = {"schemaVersion": STAGE_SCHEMA, "stages": merge_records(existing, records)}
    temporary = path.with_name(path.name + f".tmp{os.getpid()}")
    temporary.write_text(json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
                         encoding="utf-8", newline="\n")
    os.replace(temporary, path)


def _pump(stream, mirror, sink) -> None:
    try:
        for line in iter(stream.readline, b""):
            mirror.write(line)
            mirror.flush()
            sink.write(line)
            sink.flush()
    finally:
        stream.close()


def _mirror_streams(process: subprocess.Popen, log_path: Path) -> list[threading.Thread]:
    """Pass stdout/stderr through unchanged while teeing them into one log."""
    handle = log_path.open("wb")
    threads = [
        threading.Thread(target=_pump, args=(process.stdout, sys.stdout.buffer, handle), daemon=True),
        threading.Thread(target=_pump, args=(process.stderr, sys.stderr.buffer, handle), daemon=True),
    ]
    for thread in threads:
        thread.start()
    return threads


def run_stage(stage_id: str, kind: str, command: list[str], evidence_dir: Path,
              extra: dict[str, object] | None = None) -> int:
    """Run one external stage, always writing a record, and return its exit code."""
    if kind not in STAGE_KINDS:
        raise SystemExit(f"ci_stage.py: unknown stage kind: {kind}")
    if not command:
        raise SystemExit("ci_stage.py: run requires -- and a command")
    evidence_dir = Path(evidence_dir)
    evidence_dir.mkdir(parents=True, exist_ok=True)
    handle = StageHandle(stage_id, kind, command)
    handle.record(extra)
    handle.record_value["startedAt"] = utc_now()
    started = time.perf_counter()
    cancelled: list[int] = []
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def cancel(signum, _frame):
        cancelled.append(signum)
        try:
            process.send_signal(signum)
        except ProcessLookupError:
            pass

    previous = {}
    for signum in (signal.SIGINT, signal.SIGTERM):
        try:
            previous[signum] = signal.signal(signum, cancel)
        except (ValueError, OSError):
            pass
    try:
        threads = _mirror_streams(process, evidence_dir / f"{stage_id}.log")
        returncode = process.wait()
        for thread in threads:
            thread.join(timeout=5)
    finally:
        for signum, handler in previous.items():
            signal.signal(signum, handler)
    exit_code = returncode if returncode >= 0 else 128 - returncode
    handle.record_value.update({
        "wallMs": round((time.perf_counter() - started) * 1000, 3),
        "exitCode": exit_code,
        "status": "cancelled" if cancelled else ("passed" if exit_code == 0 else "failed"),
        "endedAt": utc_now(),
        "environment": stage_environment(),
    })
    write_stage_evidence(evidence_dir / STAGES_FILE, [handle.record_value])
    return exit_code


def load_records(evidence_dir: Path) -> list[dict]:
    path = Path(evidence_dir) / STAGES_FILE
    if not path.exists():
        raise SystemExit(f"ci_stage.py: no stage evidence at {path}")
    document = json.loads(path.read_text(encoding="utf-8"))
    if document.get("schemaVersion") != STAGE_SCHEMA or not isinstance(document.get("stages"), list):
        raise SystemExit(f"ci_stage.py: unexpected stage evidence schema in {path}")
    return document["stages"]


def summarize(records: list[dict]) -> str:
    lines = ["| stage | kind | wall ms | exit | status | cache | identity |", "| --- | --- | ---: | ---: | --- | --- | --- |"]
    for item in records:
        environment = item.get("environment") or {}
        identity = f"{environment.get('platform', '')} {environment.get('checkoutCommit', '')[:12]}"
        cache = ",".join(f"{name}={state}" for name, state in sorted((environment.get("cache") or {}).items()))
        lines.append("| {stageId} | {kind} | {wallMs} | {exitCode} | {status} | {cache} | {identity} |".format(
            cache=cache or "unknown", identity=identity.strip(), **item))
    return "\n".join(lines) + "\n"


def _gh_json(path: str) -> object:
    completed = subprocess.run(["gh", "api", "--paginate", path], capture_output=True, text=True)
    if completed.returncode != 0:
        raise SystemExit(f"ci_stage.py: gh api failed for {path}: {completed.stderr.strip()}")
    return json.loads(completed.stdout)


def _milliseconds(start: str | None, end: str | None) -> int:
    if not start or not end:
        return 0
    parse = lambda value: dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    return max(0, round((parse(end) - parse(start)).total_seconds() * 1000))


def wallclock(run_id: str, attempt: int, repository: str) -> dict[str, object]:
    """Read-only wall-clock classification from the Actions jobs API."""
    run = _gh_json(f"repos/{repository}/actions/runs/{run_id}")
    if not isinstance(run, dict):
        raise SystemExit("ci_stage.py: unexpected run payload")
    jobs_payload = _gh_json(
        f"repos/{repository}/actions/runs/{run_id}/jobs?filter=latest&per_page=100")
    jobs = jobs_payload.get("jobs", []) if isinstance(jobs_payload, dict) else []
    jobs = [job for job in jobs if job.get("run_attempt") == attempt]
    job_wall: dict[str, int] = {}
    step_wall: dict[str, dict[str, int]] = {}
    for job in jobs:
        name = job.get("name", "")
        job_wall[name] = _milliseconds(job.get("started_at"), job.get("completed_at"))
        if job.get("steps"):
            step_wall[name] = {step.get("name", ""): _milliseconds(step.get("started_at"), step.get("completed_at"))
                               for step in job["steps"] if step.get("completed_at")}
    started = [job["started_at"] for job in jobs if job.get("started_at")]
    queued_ms = _milliseconds(run.get("created_at"), min(started)) if started else 0
    partial = int(run.get("run_attempt", attempt)) > 1 or any(
        int(job.get("run_attempt", attempt)) > 1 for job in jobs)
    rerun_gaps = [
        {"job": job.get("name", ""), "runAttempt": job.get("run_attempt"),
         "gapMs": _milliseconds(run.get("run_started_at"), job.get("started_at"))}
        for job in jobs if int(job.get("run_attempt", attempt)) > 1
    ]
    return {
        "schemaVersion": WALLCLOCK_SCHEMA,
        "runId": str(run_id),
        "attempt": attempt,
        "workflow": run.get("name", ""),
        "headSha": run.get("head_sha", ""),
        "queuedMs": queued_ms,
        "jobWallMs": job_wall,
        "stepWallMs": step_wall,
        "manualRerunGapMs": rerun_gaps,
        "partialRerun": partial,
    }


def verify_identity(manifest_path: Path, main_binary: Path | None, worker_binary: Path | None,
                    repo: Path | None) -> int:
    """Re-read real artifacts and fail on the first identity difference."""
    manifest = json.loads(Path(manifest_path).read_text(encoding="utf-8"))
    if manifest.get("schemaVersion") != BUILD_MANIFEST_SCHEMA:
        raise SystemExit(f"ci_stage.py: unexpected build manifest schema: {manifest.get('schemaVersion')}")
    problems: list[str] = []
    if repo is not None:
        for key, args in (("checkoutCommit", ("rev-parse", "HEAD")), ("checkoutTree", ("rev-parse", "HEAD^{tree}"))):
            actual = git_value(Path(repo), *args)
            if actual and actual != manifest.get(key):
                problems.append(f"{key}: manifest {manifest.get(key)} != worktree {actual}")
    for key, path in (("mainBinary", main_binary), ("workerBinary", worker_binary)):
        if path is None:
            continue
        recorded = manifest.get(key) or {}
        path = Path(path)
        if not path.is_file():
            problems.append(f"{key}: missing {path}")
            continue
        digest, size = sha256_file(path), path.stat().st_size
        if recorded.get("sha256") != digest:
            problems.append(f"{key}.sha256: manifest {recorded.get('sha256')} != actual {digest}")
        if recorded.get("size") != size:
            problems.append(f"{key}.size: manifest {recorded.get('size')} != actual {size}")
        if key == "mainBinary" and recorded.get("versionOutput"):
            completed = subprocess.run([str(path), "--version"], capture_output=True, text=True)
            actual_version = completed.stdout.strip()
            if actual_version != recorded["versionOutput"]:
                problems.append(
                    f"{key}.versionOutput: manifest {recorded['versionOutput']!r} != actual {actual_version!r}")
    if problems:
        for problem in problems:
            print(f"identity mismatch: {problem}", file=sys.stderr)
        return 1
    print("ci build identity verified")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    run_parser = commands.add_parser("run", help="time one external command")
    run_parser.add_argument("--id", required=True)
    run_parser.add_argument("--kind", required=True, choices=sorted(STAGE_KINDS))
    run_parser.add_argument("--evidence", type=Path, required=True)
    run_parser.add_argument("--cache", help="comma-separated name=hit|miss|unknown")
    run_parser.add_argument("--extra", help="inline JSON merged into the stage record")
    run_parser.add_argument("argv", nargs=argparse.REMAINDER)
    summarize_parser = commands.add_parser("summarize")
    summarize_parser.add_argument("--evidence", type=Path, required=True)
    summarize_parser.add_argument("--output", type=Path, required=True)
    wall_parser = commands.add_parser("wallclock")
    wall_parser.add_argument("--run", required=True)
    wall_parser.add_argument("--attempt", type=int, default=1)
    wall_parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY", ""))
    wall_parser.add_argument("--output", type=Path, default=Path("target/ci-evidence/wallclock.json"))
    identity_parser = commands.add_parser("verify-identity")
    identity_parser.add_argument("--manifest", type=Path, required=True)
    identity_parser.add_argument("--main-binary", type=Path)
    identity_parser.add_argument("--worker-binary", type=Path)
    identity_parser.add_argument("--repo", type=Path)
    args = parser.parse_args(argv)

    if args.command == "run":
        command = args.argv[1:] if args.argv[:1] == ["--"] else args.argv
        if args.cache:
            os.environ["CJDOC_CACHE_STATE"] = args.cache
        extra = json.loads(args.extra) if args.extra else {}
        return run_stage(args.id, args.kind, command, args.evidence, extra)
    if args.command == "summarize":
        args.output.write_text(summarize(load_records(args.evidence)), encoding="utf-8", newline="\n")
        return 0
    if args.command == "wallclock":
        if not args.repository:
            raise SystemExit("ci_stage.py: wallclock needs --repository or GITHUB_REPOSITORY")
        classification = wallclock(args.run, args.attempt, args.repository)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(classification, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
                               encoding="utf-8", newline="\n")
        return 0
    return verify_identity(args.manifest, args.main_binary, args.worker_binary, args.repo)


if __name__ == "__main__":
    raise SystemExit(main())
