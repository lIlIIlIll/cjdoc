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

try:
    from .sts_compile_override import PRODUCT_OPTIONS, PRODUCT_REASON, UNIT_OPTIONS, UNIT_REASON
    from .compiler_failure_evidence import compiler_failure_evidence
    from .native_compiler_capture import NativeCompilerCapture
    from .ci_wallclock import classify_wallclock
except ImportError:
    from sts_compile_override import PRODUCT_OPTIONS, PRODUCT_REASON, UNIT_OPTIONS, UNIT_REASON
    from compiler_failure_evidence import compiler_failure_evidence
    from native_compiler_capture import NativeCompilerCapture
    from ci_wallclock import classify_wallclock
STAGE_SCHEMA = "cjdoc.ci-stage/1"
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
_COMPILE_OPTIONS = ("--jobs 1", *PRODUCT_OPTIONS)


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def git_value(repo: Path, *args: str) -> str | None:
    """The value `git` prints, or `None` when it could not answer at all.

    An empty string used to mean both "git says this value is empty" and "git never
    ran", and callers read it as "no information, skip the comparison" -- so a
    non-repository `--repo` printed `ci build identity verified` without ever
    comparing the manifest to a worktree. `None` keeps the two apart.
    """
    try:
        completed = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True)
    except OSError:
        # A missing `git` executable is the same condition, not a crash.
        return None
    if completed.returncode != 0:
        return None
    value = completed.stdout.strip()
    return value or None


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
    """Digest font families and version metadata fontconfig resolves, or return `""`.

    DONE-03 puts the font set in the matched condition because font substitution
    changes browser rendering. Family names alone miss same-family font updates.
    Fontconfig's version metadata captures those updates without reading every font
    file; incomplete listings are unavailable rather than partial evidence.
    """
    try:
        completed = subprocess.run(["fc-list", "--format", "%{family}\\t%{fontversion}\\n"],
                                   capture_output=True, text=True, check=True)
    except (OSError, subprocess.CalledProcessError):
        return ""
    font_versions: set[tuple[str, str]] = set()
    for line in completed.stdout.splitlines():
        family, separator, version = line.partition("\t")
        family, version = family.strip(), version.strip()
        if not separator or not family or not version:
            return ""
        font_versions.add((family, version))
    if not font_versions:
        return ""
    identity = "\n".join(f"{family}\t{version}" for family, version in sorted(font_versions))
    return hashlib.sha256(b"cjdoc-font-set-version-v1\0" + identity.encode("utf-8")).hexdigest()


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


def stage_environment(repo: Path | None = None, *, kind: str | None = None) -> dict[str, object]:
    """Identity fields that must stay stable across producers and consumers."""
    repo = Path(repo or os.environ.get("CJDOC_REPO", ".")).resolve()
    platform_id, os_name = runtime_platform()
    wrapped = bool(os.environ.get("CJDOC_REAL_CJPM"))
    compile_options = list(_COMPILE_OPTIONS) if wrapped else []
    compile_reason = PRODUCT_REASON if wrapped else ""
    if wrapped and kind == "native":
        compile_options = ["--jobs 1", *UNIT_OPTIONS]
        compile_reason = UNIT_REASON
    return {
        "checkoutCommit": os.environ.get("GITHUB_SHA") or git_value(repo, "rev-parse", "HEAD") or "",
        "checkoutTree": git_value(repo, "rev-parse", "HEAD^{tree}") or "",
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
        "compileReason": compile_reason,
        "productCompileOptions": list(_COMPILE_OPTIONS) if wrapped else [],
        "unitTargetIsolation": "fresh-target-dir" if wrapped and kind == "native" else "",
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
        "environment": stage_environment(repo, kind=kind),
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


def _pump(stream, mirror, sink, observer=None) -> None:
    try:
        for line in iter(stream.readline, b""):
            # The console always receives the full stream; only the retained file
            # is bounded.
            mirror.write(line)
            mirror.flush()
            if observer is not None:
                observer(line)
            sink.write(line)
    finally:
        stream.close()


def _mirror_streams(process: subprocess.Popen, log_path: Path, observer=None) -> tuple[threading.Thread, ...]:
    """Pass stdout/stderr through unchanged while teeing them into one bounded log."""
    handle = _BoundedLog(log_path)
    threads = [
        threading.Thread(target=_pump, args=(process.stdout, sys.stdout.buffer, handle, observer), daemon=True),
        threading.Thread(target=_pump, args=(process.stderr, sys.stderr.buffer, handle, observer), daemon=True),
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
              extra: dict[str, object] | None = None, *, capture_native_compiler: bool = False) -> int:
    """Run one external stage, always writing a record, and return its exit code."""
    if kind not in STAGE_KINDS:
        raise SystemExit(f"ci_stage.py: unknown stage kind: {kind}")
    if not command:
        raise SystemExit("ci_stage.py: run requires -- and a command")
    if capture_native_compiler and (sys.platform != "win32" or stage_id != "provider" or kind != "provider"):
        raise SystemExit("ci_stage.py: native compiler capture requires the Windows provider stage")
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
    capture = None
    if capture_native_compiler:
        diagnostic = None
        try:
            capture = NativeCompilerCapture.prepare(evidence_dir, child_environment)
            if not capture.active:
                diagnostic = capture.finish(1, evidence_dir / f"{stage_id}.log")
        except Exception:
            diagnostic = {"status": "unavailable", "reason": "capture-setup-failed"}
        if diagnostic is not None:
            handle.record_value.update({
                "wallMs": round((time.perf_counter() - started) * 1000, 3),
                "exitCode": 1, "status": "failed", "endedAt": utc_now(),
                "environment": stage_environment(kind=kind),
                "nativeCompilerEvidence": diagnostic,
            })
            write_stage_evidence(evidence_dir / STAGES_FILE, [handle.record_value])
            return 1
    try:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   env=child_environment)
    except OSError:
        if capture is None:
            raise
        try:
            diagnostic = capture.finish(1, evidence_dir / f"{stage_id}.log")
        except Exception:
            diagnostic = {"status": "unavailable", "reason": "capture-finalization-failed",
                          "stageExitCode": 1}
        handle.record_value.update({
            "wallMs": round((time.perf_counter() - started) * 1000, 3),
            "exitCode": 1, "status": "failed", "endedAt": utc_now(),
            "environment": stage_environment(kind=kind),
            "nativeCompilerEvidence": diagnostic,
        })
        write_stage_evidence(evidence_dir / STAGES_FILE, [handle.record_value])
        return 1

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
        threads = _mirror_streams(process, evidence_dir / f"{stage_id}.log",
                                  capture.observe if capture is not None else None)
        returncode = process.wait()
        for thread in threads:
            thread.join(timeout=None if capture is not None else 5)
    finally:
        for signum, handler in previous.items():
            signal.signal(signum, handler)
    exit_code = returncode if returncode >= 0 else 128 - returncode
    environment = stage_environment(kind=kind)
    if capture is not None:
        try:
            diagnostic = capture.finish(exit_code, evidence_dir / f"{stage_id}.log")
        except Exception:
            diagnostic = {"status": "unavailable", "reason": "capture-finalization-failed",
                          "stageExitCode": exit_code}
        handle.record_value["nativeCompilerEvidence"] = diagnostic
        handle.record_value["programExitCode"] = exit_code
        diagnostic_options = ["-V", "--save-temps", "<native-compiler-ir>"]
        environment["diagnosticCompileOptions"] = diagnostic_options
        environment["compileOptions"] = [*environment["compileOptions"], *diagnostic_options]
        if exit_code == 0 and diagnostic.get("status") != "recorded":
            exit_code = 1
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
    if sys.platform == "win32" and kind == "provider" and exit_code != 0:
        compiler_failure = compiler_failure_evidence(
            "provider", [("stage-log", evidence_dir / f"{stage_id}.log")])
        if compiler_failure is not None:
            handle.record_value["compilerFailure"] = compiler_failure
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
                    repo: Path | None, require_runnable: bool = True,
                    require_worktree: bool = True) -> int:
    """Re-read real artifacts and fail on the first identity difference.

    Digest and size checks always apply. The recorded `--version` output is only
    meaningful where the binary can actually start: the Cangjie executable is
    dynamically linked, so a job without the toolchain runtime (for example the
    Pages site assembly job, which only needs the bytes) cannot execute it. Set
    `require_runnable=False` there; the digest still binds the artifact.

    The worktree comparison is the manifest's promise that the bytes were built from
    this checkout. It used to be skipped whenever `git` could not answer, which
    turned an unreadable `--repo` into a reported success; `--repo` given but
    unreadable is now a problem, and a caller that genuinely has no worktree passes
    an explicit `--no-worktree-identity` (`require_worktree=False`) instead.
    """
    manifest = json.loads(Path(manifest_path).read_text(encoding="utf-8"))
    if manifest.get("schemaVersion") != BUILD_MANIFEST_SCHEMA:
        raise SystemExit(f"ci_stage.py: unexpected build manifest schema: {manifest.get('schemaVersion')}")
    problems: list[str] = []
    if repo is not None:
        if not require_worktree:
            print("identity note: worktree identity is not compared for this job; "
                  "the digest and size still bind the artifact")
        else:
            for key, args in (("checkoutCommit", ("rev-parse", "HEAD")),
                              ("checkoutTree", ("rev-parse", "HEAD^{tree}"))):
                actual = git_value(Path(repo), *args)
                if actual is None:
                    problems.append(f"{key}: cannot read worktree identity from {repo}")
                elif actual != manifest.get(key):
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
    run_parser.add_argument("--capture-native-compiler", action="store_true",
                            help="retain first-attempt Windows provider compiler identities and safe failed IR")
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
    identity_parser.add_argument(
        "--no-worktree-identity", action="store_true",
        help="this job has no worktree to compare; say so instead of reading an "
             "unreadable `--repo` as a match")
    args = parser.parse_args(argv)

    if args.command == "run":
        command = args.argv[1:] if args.argv[:1] == ["--"] else args.argv
        if args.cache:
            os.environ["CJDOC_CACHE_STATE"] = args.cache
        extra = json.loads(args.extra) if args.extra else {}
        return run_stage(args.id, args.kind, command, args.evidence, extra,
                         capture_native_compiler=args.capture_native_compiler)
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
                          require_runnable=not args.skip_version_check,
                          require_worktree=not args.no_worktree_identity)


if __name__ == "__main__":
    raise SystemExit(main())
