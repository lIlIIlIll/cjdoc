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
WALLCLOCK_SCHEMA = "cjdoc.ci-wallclock/2"
BUILD_MANIFEST_SCHEMA = "cjdoc.ci-build-manifest/1"
STAGE_KINDS = frozenset({
    "build", "native", "python", "cli", "provider", "smoke", "site-assemble",
    "browser-shard", "browser", "reading", "source-reproduction", "merge", "package",
    "publish", "sdk",
})
STAGES_FILE = "stages.json"
# A stage reports identity it could only learn by running (the browser build, the font
# set it rendered with) through this file. It is a declared channel rather than an
# environment variable so the value cannot be inherited by a later, unrelated stage,
# and rather than scraping stdout so a log line never becomes a measurement.
IDENTITY_REPORT_FILE = "stage-identity.json"
# The recorder exports this to the stage it launched, so the report always lands where
# that run will read it. Passing it as an environment variable rather than deriving it
# from `CJDOC_CI_EVIDENCE` keeps the channel working for every workflow: only some of
# them set that variable, and a stage that silently reported nowhere would leave the
# axis permanently unrecorded.
IDENTITY_REPORT_ENV = "CJDOC_STAGE_IDENTITY_REPORT"
# Only fields `stage_environment` already declares may be reported, and only the ones
# a stage can genuinely learn about itself. An unrestricted channel would let a stage
# forge the toolchain identity it is supposed to be measured against.
REPORTABLE_IDENTITY = frozenset({"browserVersion", "browserIdentity", "fontSetDigest"})
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


def font_set_digest() -> str:
    """A digest of the font families this machine can resolve, or `""`.

    DONE-03 puts the font set in the matched condition because a CJK fallback changes
    what the rendered pages show. There is exactly ONE implementation on purpose: two
    call sites hashing the same fonts differently would produce conditions that can
    never be equal, and every cell would silently stay unpaired.

    The digest covers the resolved families, not the font files: two runners with the
    same families render the same text, and hashing thousands of files on every run
    would cost more than the evidence is worth.
    """
    try:
        completed = subprocess.run(["fc-list", "--format", "%{family}\\n"],
                                   capture_output=True, text=True, check=True)
    except (OSError, subprocess.CalledProcessError):
        return ""
    families = sorted({line.strip() for line in completed.stdout.splitlines() if line.strip()})
    if not families:
        return ""
    return hashlib.sha256("\n".join(families).encode("utf-8")).hexdigest()


def report_identity(values: dict[str, str], path: Path | None = None) -> None:
    """Publish what this stage actually ran with, for `ci_stage` to record.

    `path` is the report FILE. It defaults to the recorder's environment, so a stage
    always writes to the place its own run will read. No-op outside the recorder (a
    developer invoking the stage directly), where no file would be read anyway.
    """
    target = path if path is not None else os.environ.get(IDENTITY_REPORT_ENV)
    if not target:
        return
    payload = {field: str(values.get(field) or "") for field in sorted(REPORTABLE_IDENTITY)}
    target = Path(target)
    target.parent.mkdir(parents=True, exist_ok=True)
    # Written to a sibling and moved into place: the recorder reads this file after the
    # stage exits, and a stage killed mid-write must not leave a truncated document that
    # the recorder would then reject as malformed.
    staging = target.with_name(target.name + ".partial")
    staging.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
                       encoding="utf-8", newline="\n")
    staging.replace(target)


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
        # Present but empty until a stage reports them, so every artifact carries the
        # same key set and a missing axis is visible as an empty value rather than as
        # an absent field that a consumer might read as "not applicable".
        **{field: "" for field in sorted(REPORTABLE_IDENTITY)},
    }


def read_reported_identity(path: Path) -> dict[str, str]:
    """The identity a stage reported about itself, or `{}` when it reported none.

    Read only from the file this run owns, and only for the declared fields: a stage
    that writes an unknown key is a defect, not extra evidence, so it fails loudly
    instead of silently adding a field nothing validates.
    """
    path = Path(path)
    if not path.is_file():
        return {}
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        # Not fatal: the stage's own record is the evidence, and aborting here would
        # destroy it so the whole job disappears from the sample instead of appearing
        # with an unrecorded axis. A stage that cannot report identity has recorded
        # nothing, which is exactly what an absent report means.
        print(f"ci_stage.py: ignoring unreadable stage identity report {path}: {error}",
              file=sys.stderr)
        return {}
    if not isinstance(payload, dict):
        print(f"ci_stage.py: ignoring non-object stage identity report {path}",
              file=sys.stderr)
        return {}
    unknown = set(payload) - REPORTABLE_IDENTITY
    if unknown:
        # Undeclared fields stay fatal: they mean the producer and the recorder disagree
        # about the contract, which is a defect rather than missing evidence.
        raise SystemExit(
            f"ci_stage.py: stage identity report has undeclared field(s): {sorted(unknown)}")
    return {field: str(payload.get(field) or "") for field in REPORTABLE_IDENTITY}


class StageHandle:
    """Mutable per-stage record; `record()` merges extra evidence into it."""

    # Owned by the recorder; a caller must never overwrite the lifecycle fields.
    RESERVED = frozenset({"stageId", "kind", "command", "wallMs", "exitCode", "status",
                          "startedAt", "endedAt", "timingSource", "environment"})

    def __init__(self, stage_id: str, kind: str, command: list[str]) -> None:
        self.record_value: dict[str, object] = {
            "stageId": stage_id,
            "kind": kind,
            "command": list(command),
            "timingSource": "monotonic",
        }

    def record(self, extra: dict[str, object] | None = None) -> dict[str, object]:
        if extra:
            reserved = set(extra) & (self.RESERVED | set(self.record_value))
            if reserved:
                raise SystemExit(f"ci_stage.py: stage evidence overwrites fields: {sorted(reserved)}")
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


# Retained stage logs are diagnostic evidence, not a transcript: a verbose
# compiler or test loop must not fill the runner disk or blow the artifact limit.
LOG_HEAD_BYTES = 262_144
LOG_TAIL_BYTES = 262_144


class _BoundedLog:
    """Append-only log that keeps a bounded head and tail of the stream."""

    def __init__(self, path: Path) -> None:
        self.handle = path.open("wb")
        self.head = bytearray()
        self.tail = bytearray()
        self.skipped = 0

    def write(self, block: bytes) -> None:
        if len(self.head) < LOG_HEAD_BYTES:
            room = LOG_HEAD_BYTES - len(self.head)
            self.head.extend(block[:room])
            block = block[room:]
        if not block:
            return
        self.tail.extend(block)
        overflow = len(self.tail) - LOG_TAIL_BYTES
        if overflow > 0:
            del self.tail[:overflow]
            self.skipped += overflow

    def flush(self) -> None:
        return None

    def close(self) -> None:
        if self.skipped:
            self.handle.write(
                f"\n... {self.skipped} bytes omitted by the log bound ...\n".encode("utf-8"))
        self.handle.write(bytes(self.head))
        self.handle.write(bytes(self.tail))
        self.handle.close()


def _pump(stream, mirror, sink) -> None:
    try:
        for line in iter(stream.readline, b""):
            # The console always receives the full stream; only the retained file
            # is bounded.
            mirror.write(line)
            mirror.flush()
            sink.write(line)
    finally:
        stream.close()


def _mirror_streams(process: subprocess.Popen, log_path: Path) -> tuple[threading.Thread, ...]:
    """Pass stdout/stderr through unchanged while teeing them into one bounded log."""
    handle = _BoundedLog(log_path)
    threads = [
        threading.Thread(target=_pump, args=(process.stdout, sys.stdout.buffer, handle), daemon=True),
        threading.Thread(target=_pump, args=(process.stderr, sys.stderr.buffer, handle), daemon=True),
    ]
    # The last finishing pump closes the log handle; each pump closes only its own
    # stream, so the shared log handle is closed once, after both writers are done.
    closer = threading.Thread(target=_close_after, args=(threads, handle), daemon=True)
    for thread in threads:
        thread.start()
    closer.start()
    return (*threads, closer)


def _close_after(threads: list[threading.Thread], handle) -> None:
    for thread in threads:
        thread.join()
    handle.close()


def run_stage(stage_id: str, kind: str, command: list[str], evidence_dir: Path,
              extra: dict[str, object] | None = None) -> int:
    """Run one external stage, always writing a record, and return its exit code."""
    if kind not in STAGE_KINDS:
        raise SystemExit(f"ci_stage.py: unknown stage kind: {kind}")
    if not command:
        raise SystemExit("ci_stage.py: run requires -- and a command")
    evidence_dir = Path(evidence_dir)
    evidence_dir.mkdir(parents=True, exist_ok=True)
    # A report left by an earlier stage must never be inherited by this one: the file
    # describes what a stage ran WITH, so a stale copy would attribute one stage's
    # browser identity to a later stage that recorded none.
    (evidence_dir / IDENTITY_REPORT_FILE).unlink(missing_ok=True)
    handle = StageHandle(stage_id, kind, command)
    handle.record(extra)
    handle.record_value["startedAt"] = utc_now()
    started = time.perf_counter()
    cancelled: list[int] = []
    # The stage learns the path from the recorder, so it always writes where THIS run
    # reads.
    child_environment = dict(os.environ)
    child_environment[IDENTITY_REPORT_ENV] = str(evidence_dir / IDENTITY_REPORT_FILE)
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               env=child_environment)

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
    environment = stage_environment()
    # Read only after the stage has ended: the value it reports is what it actually
    # ran with. The file is a one-shot channel, so it is deleted once consumed --
    # `stages.json` is the evidence, and a leftover copy would be uploaded as if it
    # were a separate measurement.
    report = evidence_dir / IDENTITY_REPORT_FILE
    environment.update(read_reported_identity(report))
    report.unlink(missing_ok=True)
    handle.record_value.update({
        "wallMs": round((time.perf_counter() - started) * 1000, 3),
        "exitCode": exit_code,
        "status": "cancelled" if cancelled else ("passed" if exit_code == 0 else "failed"),
        "endedAt": utc_now(),
        "environment": environment,
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


def _gh_json(path: str, *, paginate: bool = True, tries: int = 5) -> object:
    """Read one REST resource.

    `--paginate` concatenates the JSON of every page, so the response is decoded
    as a stream instead of a single document; a jobs listing is routinely more
    than one page. The API also returns transient EOFs on large runs, which would
    otherwise lose the evidence of an otherwise successful run, so the read is
    retried before giving up.
    """
    args = ["gh", "api"] + (["--paginate"] if paginate else []) + [path]
    last = ""
    for attempt in range(tries):
        completed = subprocess.run(args, capture_output=True, text=True)
        if completed.returncode == 0:
            # A truncated or EMPTY body is a transient failure too: `gh api` can exit
            # 0 with a cut-off page or no body at all (the EOF this retry loop exists
            # for). Accepting an empty body would make the run endpoint abort with an
            # unexpected payload and the jobs endpoint silently record no timing,
            # losing exactly the evidence this command preserves, so it is retried
            # and only then falls back to `{}`.
            if not completed.stdout.strip():
                last = "empty response body"
            else:
                try:
                    decoder = json.JSONDecoder()
                    text = completed.stdout
                    values: list[object] = []
                    index = 0
                    while index < len(text):
                        while index < len(text) and text[index] in " \t\r\n":
                            index += 1
                        if index >= len(text):
                            break
                        value, index = decoder.raw_decode(text, index)
                        values.append(value)
                except ValueError as error:
                    last = f"malformed JSON response: {error}"
                else:
                    if not values:
                        return {}
                    if len(values) == 1:
                        return values[0]
                    merged: dict[str, object] = {}
                    for value in values:
                        if not isinstance(value, dict):
                            continue
                        for key, item in value.items():
                            if isinstance(item, list):
                                existing = merged.setdefault(key, [])
                                if isinstance(existing, list):
                                    existing.extend(item)
                            else:
                                merged.setdefault(key, item)
                    return merged
        else:
            last = completed.stderr.strip()
        if attempt + 1 < tries:
            time.sleep(2 * (attempt + 1))
    raise SystemExit(f"ci_stage.py: gh api failed for {path}: {last[:300]}")


def _milliseconds(start: str | None, end: str | None) -> int:
    if not start or not end:
        return 0
    parse = lambda value: dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    return max(0, round((parse(end) - parse(start)).total_seconds() * 1000))


def non_overlapping_chain(intervals: list[tuple[str, int, int]]) -> dict[str, object]:
    """The longest chain of jobs that did not overlap in time.

    Derived only from observed start/end times, because the Jobs API reports no
    dependency graph. A job extends the chain when it started no earlier than the
    previous one ended.

    This is NOT the dependency critical path, and the field names say `chain`
    rather than `criticalPath` for that reason. Two independent jobs -- `pages.yml`'s
    source reproduction and its browser shards are siblings that each need only
    `assemble-site` -- can be serialized by runner availability, and a chain built
    from timestamps alone would then join them and exceed the real dependency path.
    The number is what actually happened, which is the question this document asks,
    but it is not an attribution of the wall clock to a `needs` edge.

    `equalsLongestJob` reports the flat case, so a reader cannot mistake "the
    longest job" for a measured chain.

    `intervals` is `(name, startMs, endMs)` with times relative to one origin.
    """
    ordered = sorted((start, end, name) for name, start, end in intervals)
    best: list[int] = []
    previous: list[int] = []
    for index, (start, end, _name) in enumerate(ordered):
        wall = max(0, end - start)
        best_index, best_total = -1, 0
        for earlier in range(index):
            if ordered[earlier][1] <= start and best[earlier] > best_total:
                best_index, best_total = earlier, best[earlier]
        best.append(best_total + wall)
        previous.append(best_index)
    if not best:
        # Every field is present here too: a consumer that reads `longestJobMs`
        # must not need a special case for a run with no timings.
        return {"chain": [], "wallMs": 0, "equalsLongestJob": True, "longestJob": "",
                "longestJobMs": 0}
    # One index decides both the chain and its wall: computing the maximum twice
    # lets a later, shorter chain overwrite the number while `chain` keeps naming
    # the longer one, so the document would contradict itself.
    peak = max(range(len(best)), key=lambda index: best[index])
    link = peak
    chain: list[str] = []
    while link != -1:
        chain.append(ordered[link][2])
        link = previous[link]
    chain.reverse()
    longest = max(ordered, key=lambda item: item[1] - item[0])
    return {
        "chain": chain,
        "wallMs": best[peak],
        # True means the run was flat: no chain is longer than its single longest
        # job, so attributing the wall clock to a sequence would be invented.
        "equalsLongestJob": len(chain) == 1,
        "longestJob": longest[2],
        "longestJobMs": max(0, longest[1] - longest[0]),
    }


def classify_wallclock(run: dict[str, object], jobs_payload: dict[str, object],
                       attempt: int) -> dict[str, object]:
    """Build the wall-clock document from already-fetched API payloads."""
    jobs = jobs_payload.get("jobs", []) if isinstance(jobs_payload, dict) else []
    jobs = [job for job in jobs if job.get("run_attempt") == attempt]
    started = [job["started_at"] for job in jobs if job.get("started_at")]
    latest_attempt = int(run.get("run_attempt", attempt))
    run_origin = run.get("run_started_at") or run.get("created_at")
    job_wall: dict[str, int] = {}
    step_wall: dict[str, dict[str, int]] = {}
    # A re-run copies the previous attempt's unchanged job records with their original
    # timestamps. Those jobs did not run in this attempt, so they get the same 0 ms a
    # skipped job gets -- anywhere else their durations would be counted twice across
    # attempts and would contradict the chain, which drops them.
    #
    # The test is a completed record that ended before the run origin. A job that has
    # not completed is still running in this attempt, and classifying mid-run must
    # keep the steps it has recorded so far; scoping to the latest attempt keeps an
    # older attempt's own records intact, since only that attempt's jobs can be
    # mistaken for carried ones.
    carried = {
        id(job) for job in jobs
        if attempt == latest_attempt and run_origin
        and job.get("completed_at") and job["completed_at"] < run_origin
    }
    for job in jobs:
        name = job.get("name", "")
        if id(job) in carried:
            job_wall[name] = 0
            continue
        job_wall[name] = _milliseconds(job.get("started_at"), job.get("completed_at"))
        if job.get("steps"):
            step_wall[name] = {step.get("name", ""): _milliseconds(step.get("started_at"), step.get("completed_at"))
                               for step in job["steps"] if step.get("completed_at")}
    partial = latest_attempt > 1 or any(
        int(job.get("run_attempt", attempt)) > 1 for job in jobs)
    rerun_gaps = [
        {"job": job.get("name", ""), "runAttempt": job.get("run_attempt"),
         "gapMs": _milliseconds(run.get("run_started_at"), job.get("started_at"))}
        for job in jobs if int(job.get("run_attempt", attempt)) > 1
    ]
    # The origin depends on which attempt is being described, because the two
    # cases have opposite failure modes:
    #
    # * latest attempt -- `run_started_at` is its own origin, and a re-run carries
    #   the previous attempt's unchanged job records with their original
    #   timestamps. Anchoring on the earliest job start would then measure from
    #   before this attempt existed: a span longer than the run's own wall and a
    #   chain outlasting the run. Anchored on the run origin those carried records
    #   clamp to zero length and drop out, which is the truth: this attempt did not
    #   run them.
    # * older attempt -- the reverse. `run_started_at` belongs to the latest
    #   attempt, so every job of this one lands before the origin and clamps to
    #   (0, 0): a non-zero wall beside a zero span and a chain that lost every job.
    #   The attempt's own jobs are the only available origin.
    if attempt >= latest_attempt and run_origin:
        anchor = run_origin
    else:
        anchor = min(started) if started else None
    # Carried records are excluded here too, not merely clamped: against the anchor
    # they would clamp to a start of 0, which becomes the minimum, so the span would
    # run from the attempt origin instead of from the first job that actually ran.
    # `wall - job span` is documented as the pre-start gap plus the post-completion
    # tail, so a phantom 0 start would report no queueing at all.
    intervals = [
        (job.get("name", ""), _milliseconds(anchor, job.get("started_at")),
         _milliseconds(anchor, job.get("completed_at")))
        for job in jobs
        if job.get("started_at") and job.get("completed_at") and id(job) not in carried
    ]
    # The three clocks `docs/ci-wallclock.md` tabulates, computed here rather than in
    # the table's author: a number a reader cannot reproduce from the artifact is not
    # evidence. `wall` is what a user waits for; the job span excludes the
    # controller's own pre-start queueing; job-minutes do not hide parallel work.
    #
    # `updated_at` is also a run-level timestamp, so for an older attempt it ends
    # the latest attempt rather than this one. There the number is not a wall at
    # all, and `wallSource` says so instead of publishing an overstatement.
    if attempt == latest_attempt:
        wall_ms = _milliseconds(run_origin, run.get("updated_at"))
        wall_source = "run"
    else:
        # An older attempt, or one the run never had: either way the run-level wall
        # is not this attempt's, and publishing it beside an empty job list would
        # read as a measured run that simply had no jobs.
        wall_ms = 0
        wall_source = "attempt-jobs"
    # Queueing is the wait before this attempt's first job starts, so both ends must
    # belong to this attempt. `created_at` is when the RUN was created, which for a
    # re-run is the first attempt's creation: measured from there, a re-run reports
    # the interval spanning the previous attempt as its own queue delay. A re-run's
    # own start is `run_started_at`, so that is the origin it gets.
    queue_origin = run.get("created_at") if attempt <= 1 else run_origin
    in_attempt = [start for start in started if start >= (queue_origin or start)]
    queued_ms = _milliseconds(queue_origin, min(in_attempt)) if in_attempt else 0
    job_span_ms = (max(end for _name, _start, end in intervals)
                   - min(start for _name, start, _end in intervals)) if intervals else 0
    if wall_source == "attempt-jobs":
        # Same span, reported as the wall: this attempt has no run-level wall to
        # read, and 0 next to a non-zero span would read as a measurement.
        wall_ms = job_span_ms
    return {
        "schemaVersion": WALLCLOCK_SCHEMA,
        "runId": str(run.get("id", "")),
        "attempt": attempt,
        "workflow": run.get("name", ""),
        "headSha": run.get("head_sha", ""),
        "queuedMs": queued_ms,
        "wallMs": wall_ms,
        "wallSource": wall_source,
        "jobSpanMs": job_span_ms,
        "jobMinutes": round(sum(job_wall.values()) / 60_000, 1),
        "jobWallMs": job_wall,
        "stepWallMs": step_wall,
        "nonOverlappingChain": non_overlapping_chain(intervals),
        "manualRerunGapMs": rerun_gaps,
        "partialRerun": partial,
    }


def wallclock(run_id: str, attempt: int, repository: str) -> dict[str, object]:
    """Read-only wall-clock classification from the Actions jobs API."""
    run = _gh_json(f"repos/{repository}/actions/runs/{run_id}", paginate=False)
    if not isinstance(run, dict):
        raise SystemExit("ci_stage.py: unexpected run payload")
    # `filter=all`, not `filter=latest`: the classifier selects the attempt it was
    # asked for, and `latest` would hand it only the newest one. Classifying an
    # earlier attempt of a re-run run would then find no jobs and report a complete,
    # plausible document of zeros instead of that attempt's timings.
    jobs_payload = _gh_json(
        f"repos/{repository}/actions/runs/{run_id}/jobs?filter=all&per_page=100")
    document = classify_wallclock(run, jobs_payload, attempt)
    document["runId"] = str(run_id)
    return document


def verify_identity(manifest_path: Path, main_binary: Path | None, worker_binary: Path | None,
                    repo: Path | None, require_runnable: bool = True) -> int:
    """Re-read real artifacts and fail on the first identity difference.

    Digest and size checks always apply. The recorded `--version` output is only
    meaningful where the binary can actually start: the Cangjie executable is
    dynamically linked, so a job without the toolchain runtime (for example the
    Pages site assembly job, which only needs the bytes) cannot execute it. Set
    `require_runnable=False` there; the digest still binds the artifact.
    """
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
        if key != "mainBinary":
            continue
        recorded_version = recorded.get("versionOutput")
        if not recorded_version:
            problems.append(f"{key}.versionOutput: manifest does not record the binary version")
            continue
        try:
            completed = subprocess.run([str(path), "--version"], capture_output=True, text=True)
        except OSError as error:
            # A file that cannot be executed here (wrong platform, missing
            # interpreter, not a program) is a reported condition, not a crash.
            if require_runnable:
                problems.append(f"{key}.versionOutput: binary could not be executed: {error}")
            else:
                print(f"identity note: {key} cannot be executed in this job ({error}); "
                      "the digest and size still bind the artifact")
            continue
        actual_version = completed.stdout.strip()
        if actual_version != recorded_version:
            if actual_version:
                problems.append(
                    f"{key}.versionOutput: manifest {recorded_version!r} != actual {actual_version!r}")
            elif require_runnable:
                problems.append(
                    f"{key}.versionOutput: binary could not run here (exit {completed.returncode}): "
                    f"{completed.stderr.strip()[:160]}")
            else:
                print(f"identity note: {key} --version is unavailable in this job; "
                      "the digest and size still bind the artifact")
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
    identity_parser.add_argument(
        "--skip-version-check", action="store_true",
        help="the binary cannot run here; digest and size still bind the artifact")
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
    return verify_identity(args.manifest, args.main_binary, args.worker_binary, args.repo,
                          require_runnable=not args.skip_version_check)


if __name__ == "__main__":
    raise SystemExit(main())
