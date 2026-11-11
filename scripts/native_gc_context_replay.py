#!/usr/bin/env python3
"""Replay the original Linux Release context around one frozen candidate.

This tool is diagnostic evidence collection. It is not an acceptance gate, not a
release retry and not a fix. It answers one question: when the *whole* original
Linux Release precursor workload runs before the product is exercised, does the
recovered candidate fault where an isolated cold launch did not?

What it runs, in the original order and through the original scripts:

    1. ``scripts/check.sh preflight``
    2. ``scripts/check.sh build`` -- the real project build, kept only as the
       precursor load the original job performed, never as a new product
    3. seal that fresh build's own receipt privately, then put the recovered
       candidate binaries and its untouched historical build manifest back so
       every later consumer tests the recovered product
    4. ``scripts/check.sh native``, ``python-tools``, ``cli``, ``provider``
    5. ``scripts/real_repository_smoke.py`` under the original 2GB recipe
    6. ``scripts/perf_gate.py check`` under the original 512MB recipe, with the
       original prewarm and cold/warm/warm/cold order for ``basic``, then ``self``

The performance cohort runs **natively**. No live debugger is attached, because a
trace perturbs exactly the fork/signal scheduling under diagnosis. A private
kernel core is enabled for the five ``self`` invocations only, and the first
native fault is bound to the failed ``self`` process and explained offline with
GDB afterwards.

``perf_gate.py`` runs one binary for both profiles and is not edited, so the
cohort's ``--binary`` is a pass-through ``sh`` launcher that raises its own soft
core limit only when the argument vector names the subject project, then ``exec``s
the recovered product at its original path. It adds no process, prints nothing and
measures nothing; the ``basic`` samples simply exec through it unchanged. That
launcher is the one narrow adapter this replay introduces, and it is disclosed in
the manifest together with the resulting shift in what the private performance
evidence names as its binary.

Kernel-core capability is verified before any workload is spent: a tiny,
separately labeled, non-product abort probe under a credential-free environment
must produce a complete ELF core that GDB can load. A successful probe is capture
tool verification and is never product fault evidence. Where the capability is
unavailable the run fails preflight.

Published (``<output>/public``)::

    manifest.json
    diagnosis.txt
    private-evidence.p7m

Nothing else leaves the machine in the public directory. Stage logs, the fresh
build receipt, the bound core, the offline dump and all raw observations stay in
``<output>/private`` and inside the ciphertext.

Manifest schema ``cjdoc.native-gc-context-replay/1`` (this contextual
multi-invocation capture is distinct from the single-shot
``cjdoc.native-gc-diagnosis/1`` protocol, which remains usable)::

    schemaVersion, kind="diagnostic-context-replay", notAcceptance=true,
    acceptanceClaim=false, distinctFrom=<single-shot schema id>
    workflowSha, workflowRun{runId,runAttempt}
    subject{commit,tree,worktreeSha256,pathRelative}
    candidate{repository,runId,runAttempt,artifactId,tarName,tarBytes,tarSha256,
              main,worker,buildManifest,version}
    toolchain{sdkVersion,target,fingerprint,stdxDigest,cjcSha256,llcSha256,
              nativeLibraries[],lddResolved}
    runtimeLimits{coreSoftLimit,coreHardLimit,childCoreDumps,selfCoreDumps}
    runtimeRecipe{precursorHeap,perfHeap,smokeHeap,gc*,jobs,cpu,perfCycles,
                  perfOrder,profiles,deadlineSeconds}
    releasePrechecks{tag,commit,releaseClaim,tagCommit?,status,detail,
                     buildParameters{status,effectiveCompileOption,wrapperSha256}}
    coreCapability{required,supported,spool{...},probe{kind,notProductFaultEvidence,
                   probe{...},probeCoreDeleted,note}}
    precursor{purpose,stages[{id,kind,status,exitCode,durationSeconds,logBytes,
              logSha256,command[]}],freshBuild{...},identityComparison{...},
              outputSweep{...}}
    cohort{native,prewarm,order,executor,liveDebugger,selfInvocations,coreSelection,
           launcher{...},verdictIsAcceptance=false}
    capture{outcome,complete,faultObserved,signal,core{...+offline{...}},
            stageFailure{...}}
    evidence{certificateSha256,ciphertextSha256,ciphertextBytes,archiveBytes,
             archiveSha256,members[],cipher}
    postRun{sourceUnchanged,binaryUnchanged,sdkUnchanged,inputDrift?}
    status, collectorExitCode, startedAt, finishedAt, limitations[]

Exit status and ``status`` (they are different fields on purpose):

    exit 0, status 0    the complete original sequence ran, no fault observed
    exit 0, status 11   the complete sequence ran and a native fault was captured
                        with a complete kernel core bound to the failed ``self``
                        invocation
    exit 2,  status 2   incomplete: a prerequisite, a stage, core binding,
                        evidence packaging or post-run drift failed
    exit 124, status 124  the diagnostic deadline expired

Exit 0 therefore means "collection completed", never "the product is fine": the
reported ``status`` carries which observation was made, and ``notAcceptance`` is
always true. Success never changes the native outcome, never promotes a release
receipt and never qualifies a release.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import resource
import shlex
import shutil
import signal
import stat
import struct
import subprocess
import sys
import time

sys.dont_write_bytecode = True

try:
    from .native_gc_diagnosis import (
        CANDIDATE_ARTIFACT_ID,
        CANDIDATE_ATTEMPT,
        CANDIDATE_MEMBERS,
        CANDIDATE_REPOSITORY,
        CANDIDATE_RUN_ID,
        CANDIDATE_TAR_BYTES,
        CANDIDATE_TAR_NAME,
        CANDIDATE_TAR_SHA256,
        CANDIDATE_VERSION_OUTPUT,
        CERTIFICATE_SHA256,
        EXIT_COMPLETE_FAULT,
        EXIT_COMPLETE_NORMAL,
        EXIT_DEADLINE,
        EXIT_INCOMPLETE,
        HEAP,
        JOBS,
        NATIVE_LIBRARIES,
        PUBLIC_FILES,
        STDX_DIGEST,
        SUBJECT_COMMIT,
        SUBJECT_TREE,
        Incomplete,
        core_script_text,
        deterministic_archive,
        encrypt_evidence,
        extract_candidate,
        file_identity,
        minimal_environment,
        minimum_allowed_cpu,
        require_directory,
        require_regular_file,
        run_checked,
        sanitize_detail,
        sha256_file,
        summarize_core_dump,
        verify_archive,
        verify_build_manifest,
        verify_ldd,
        verify_sdk,
        write_private_json,
    )
    from .worktree_identity import exact_worktree_identity
except ImportError:  # Direct script execution.
    from native_gc_diagnosis import (
        CANDIDATE_ARTIFACT_ID,
        CANDIDATE_ATTEMPT,
        CANDIDATE_MEMBERS,
        CANDIDATE_REPOSITORY,
        CANDIDATE_RUN_ID,
        CANDIDATE_TAR_BYTES,
        CANDIDATE_TAR_NAME,
        CANDIDATE_TAR_SHA256,
        CANDIDATE_VERSION_OUTPUT,
        CERTIFICATE_SHA256,
        EXIT_COMPLETE_FAULT,
        EXIT_COMPLETE_NORMAL,
        EXIT_DEADLINE,
        EXIT_INCOMPLETE,
        HEAP,
        JOBS,
        NATIVE_LIBRARIES,
        PUBLIC_FILES,
        STDX_DIGEST,
        SUBJECT_COMMIT,
        SUBJECT_TREE,
        Incomplete,
        core_script_text,
        deterministic_archive,
        encrypt_evidence,
        extract_candidate,
        file_identity,
        minimal_environment,
        minimum_allowed_cpu,
        require_directory,
        require_regular_file,
        run_checked,
        sanitize_detail,
        sha256_file,
        summarize_core_dump,
        verify_archive,
        verify_build_manifest,
        verify_ldd,
        verify_sdk,
        write_private_json,
    )
    from worktree_identity import exact_worktree_identity


SCHEMA = "cjdoc.native-gc-context-replay/1"
KIND = "diagnostic-context-replay"

# The original Release tag for this source version. It is used only by a
# read-only precheck; this run never writes or promotes a release receipt.
RELEASE_TAG = "v0.7.8"

# Original Release job recipes. Neither is overridable.
SMOKE_HEAP = "2GB"
PERF_HEAP = HEAP

# One bounded diagnostic, never a retry loop.
WORKFLOW_DEADLINE_SECONDS = 6900
CORE_PROBE_TIMEOUT_SECONDS = 120
# A kernel core of a few hundred megabytes takes a moment to reach the spool; the
# window is generous because stopping early would discard the only fault evidence.
CORE_SETTLE_SECONDS = 120
OFFLINE_DUMP_TIMEOUT_SECONDS = 900

PROBE_SIGNAL = 6  # SIGABRT, the probe's own deliberate abort
FAULT_SIGNALS = {
    signal.SIGILL: "SIGILL",
    signal.SIGABRT: "SIGABRT",
    signal.SIGBUS: "SIGBUS",
    signal.SIGFPE: "SIGFPE",
    signal.SIGSEGV: "SIGSEGV",
}
ELF_ET_CORE = 4
NT_PRPSINFO = 3
NT_SIGINFO = 0x53494749
NT_FILE = 0x46494C45
ELF_CLASS64 = 2
ELF_DATA_LSB = 1
MAX_MAPPED_FILES = 256

COMMIT = re.compile(r"^[0-9a-f]{40}$")
DIGITS = re.compile(r"^[0-9]+$")

# Original stage order, then the two cohorts the original Linux Release job ran
# after the complete acceptance gate. Each timeout is a fail-fast bound, not a
# substitute for the original acceptance behaviour.
STAGES: tuple[tuple[str, str, int], ...] = (
    ("preflight", "python", 1800),
    ("build", "build", 3000),
    ("native", "native", 2700),
    ("python-tools", "python", 2700),
    ("cli", "cli", 4200),
    ("provider", "provider", 1800),
    ("smoke", "smoke", 2400),
    ("perf", "perf", 4200),
)
STAGE_TIMEOUTS = {stage_id: timeout for stage_id, _kind, timeout in STAGES}
STAGE_KINDS = {stage_id: kind for stage_id, kind, _timeout in STAGES}
PRECURSOR_CONSUMERS = ("native", "python-tools", "cli", "provider")

# Build trees a cjpm build creates. The harness removes only the ones it saw appear
# during its own run, so a tree that existed beforehand is reported, never deleted.
# The repository's own product tree (`<repo>/target`) is never part of the sweep.
BUILD_TREE_NAMES = frozenset({"target", "build-script-cache"})
# Bytecode is not a build tree, but `exact_worktree_identity` treats a `.pyc` under
# a tracked directory as an unexpected input. Every child gets
# PYTHONDONTWRITEBYTECODE=1, so a newly appearing `__pycache__` can only be this
# run's own residue and is removed before the identity check.
BYTECODE_NAMES = frozenset({"__pycache__"})
SWEEP_NAMES = BUILD_TREE_NAMES | BYTECODE_NAMES


class Deadline(Incomplete):
    """The diagnostic deadline expired; no further stage may start."""


@dataclass(frozen=True)
class StageResult:
    stage_id: str
    kind: str
    command: tuple[str, ...]
    exit_code: int
    duration_seconds: float
    log: Path


def utc_now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def private_json(path: Path, payload: object) -> None:
    write_private_json(path, payload)
    os.chmod(path, 0o600)


def subject_identity(subject: Path, description: str) -> dict[str, object]:
    """Exact worktree identity, reported as an incomplete run rather than a crash."""
    try:
        return exact_worktree_identity(subject, expected_commit=SUBJECT_COMMIT)
    except (OSError, ValueError) as error:
        raise Incomplete(f"{description} is not the exact frozen checkout: "
                         + sanitize_detail(str(error))) from error


# --------------------------------------------------------------------------- #
# Environment
# --------------------------------------------------------------------------- #

def child_environment(private: Path, subject: Path, sdk_root: Path,
                      sidecar: Path, sdk: dict[str, object], *, heap: str | None,
                      run_id: str, run_attempt: str) -> dict[str, str]:
    """The only environment a precursor or native child may inherit.

    Built from an allowlist on purpose: no forge token, no wildcard ``CJDOC_*``
    value from the caller and no private-key path reaches a child. The toolchain
    identity is re-asserted from this run's own verification rather than copied
    from whatever the caller exported.
    """
    native_directory = sdk["nativeDirectory"]
    tools_directory = sdk["toolsDirectory"]
    assert isinstance(native_directory, Path) and isinstance(tools_directory, Path)
    python = Path(sys.executable)
    plugins = sdk_root / "plugins" / "lib"
    library_path = [str(native_directory), str(tools_directory)]
    if plugins.is_dir():
        library_path.append(str(plugins))
    environment = minimal_environment(os.pathsep.join([
        str(sdk_root / "bin"), str(sdk_root / "tools" / "bin"),
        str(python.parent), "/usr/local/bin", "/usr/bin", "/bin",
    ]))
    environment.update({
        "HOME": str(private / "home"),
        "TMPDIR": str(private / "tmp"),
        "TMP": str(private / "tmp"),
        "TEMP": str(private / "tmp"),
        "RUNNER_TEMP": str(private / "runner-temp"),
        "GITHUB_WORKSPACE": str(subject),
        "GITHUB_SHA": SUBJECT_COMMIT,
        "GITHUB_RUN_ID": run_id,
        "GITHUB_RUN_ATTEMPT": run_attempt,
        "GITHUB_JOB": KIND,
        "CANGJIE_HOME": str(sdk_root),
        "CANGJIE_SDK_ROOT": str(sdk_root),
        "CJDOC_PYTHON": str(python),
        "CJDOC_STS_INVOCATION_LOG": str(private / "logs/sts-invocations.jsonl"),
        "LD_LIBRARY_PATH": os.pathsep.join(library_path),
        "CANGJIE_STDX_PATH": str(sidecar),
        "CJDOC_STDX_PATH": str(sidecar),
        "CJDOC_STDX_VARIANT": "static",
        "CJDOC_STDX_DIGEST": STDX_DIGEST,
        "CJDOC_STDX_LINK_OPTIONS": f"-L{sidecar}",
        "CJDOC_STDX_DEPENDENCY_DIGEST": "",
        "CJDOC_TOOLCHAIN_VERSION": sdk["sdkVersion"],
        "CJDOC_TOOLCHAIN_TARGET": sdk["target"],
        "CJDOC_TOOLCHAIN_FINGERPRINT": sdk["fingerprint"],
        "CJDOC_STDX_WRAPPED": "1",
    })
    if heap is not None:
        environment["cjHeapSize"] = heap
    return environment


# --------------------------------------------------------------------------- #
# Stage execution
# --------------------------------------------------------------------------- #

def snapshot_host() -> dict[str, object]:
    """A small boundary observation that never reads another process.

    Only machine-wide counters and this process's own cgroup are read: another
    workload's argv, environment or command line is none of this tool's business.
    A value that cannot be read is reported as absent rather than guessed.
    """
    observed: dict[str, object] = {"at": utc_now()}
    try:
        load = Path("/proc/loadavg").read_text(encoding="utf-8").split()
        observed["loadAverage"] = {
            "one": _float(load[0]), "five": _float(load[1]),
            "fifteen": _float(load[2]),
        }
        observed["runnable"] = load[3] if len(load) > 3 else None
    except (OSError, ValueError, IndexError):
        observed["loadAverage"] = None
    pressure: dict[str, object] = {}
    for resource_name in ("cpu", "io", "memory"):
        try:
            text = Path(f"/proc/pressure/{resource_name}").read_text(encoding="utf-8")
        except OSError:
            pressure[resource_name] = None
            continue
        values: dict[str, object] = {}
        for line in text.splitlines():
            keyword, _separator, rest = line.partition(" ")
            fields = dict(item.split("=", 1) for item in rest.split() if "=" in item)
            values[keyword] = {
                "avg10": _float(fields.get("avg10")),
                "avg60": _float(fields.get("avg60")),
                "avg300": _float(fields.get("avg300")),
                "total": _int(fields.get("total")),
            }
        pressure[resource_name] = values
    observed["pressure"] = pressure
    observed["cgroup"] = _cgroup_observation()
    return observed


def _float(value: object) -> float | None:
    try:
        return float(str(value))
    except (TypeError, ValueError):
        return None


def _int(value: object) -> int | None:
    try:
        return int(str(value))
    except (TypeError, ValueError):
        return None


def _cgroup_observation() -> dict[str, object] | None:
    """This process's own cgroup counters; no other process is inspected."""
    try:
        line = Path("/proc/self/cgroup").read_text(encoding="utf-8").splitlines()[0]
    except (OSError, IndexError):
        return None
    _hierarchy, _separator, relative = line.partition(":")
    _controllers, _separator, path = relative.partition(":")
    if not path:
        return None
    root = Path("/sys/fs/cgroup") / path.lstrip("/")
    if not root.is_dir():
        return None
    observed: dict[str, object] = {"path": path}
    for name, convert in (
        ("memory.current", _int), ("memory.max", str),
        ("pids.current", _int), ("pids.max", str), ("cpu.max", str),
    ):
        try:
            raw = (root / name).read_text(encoding="utf-8").strip()
        except OSError:
            observed[name] = None
            continue
        observed[name] = convert(raw)
    return observed


def run_child(command: list[str], *, cwd: Path, environment: dict[str, str],
              log: Path, stage_id: str, deadline: float) -> tuple[int, float]:
    """Run one child to completion inside the diagnostic deadline."""
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise Deadline("the diagnostic deadline expired before a stage could start")
    stage_bound = STAGE_TIMEOUTS[stage_id]
    # Only the overall diagnostic deadline maps to the deadline status; a stage that
    # hits its own fail-fast bound is an incomplete run.
    capped_by_deadline = remaining <= stage_bound
    effective = max(1, int(min(stage_bound, remaining)))
    started = time.monotonic()
    exit_code: int | None = None
    with log.open("xb") as stream:
        os.chmod(log, 0o600)
        try:
            child = subprocess.Popen(
                command, cwd=str(cwd), env=environment,
                stdin=subprocess.DEVNULL, stdout=stream,
                stderr=subprocess.STDOUT, start_new_session=True,
            )
        except OSError as error:
            raise Incomplete(
                f"a child process could not be started: {error}") from error
        try:
            exit_code = child.wait(timeout=effective)
        except subprocess.TimeoutExpired:
            for sent, wait_seconds in ((signal.SIGTERM, 30), (signal.SIGKILL, 60)):
                try:
                    os.killpg(os.getpgid(child.pid), sent)
                except (ProcessLookupError, PermissionError):
                    pass
                try:
                    exit_code = child.wait(timeout=wait_seconds)
                    break
                except subprocess.TimeoutExpired:
                    exit_code = None
            if exit_code is None:
                exit_code = -signal.SIGKILL
            message = (f"the {stage_id} stage exceeded its bound and was terminated")
            if capped_by_deadline:
                raise Deadline(message)
            raise Incomplete(message)
    return exit_code, round(time.monotonic() - started, 3)


class Replay:
    """Run the original stages in order against the frozen subject."""

    def __init__(self, *, subject: Path, private: Path, deadline: float,
                 environment: dict[str, str]) -> None:
        self.subject = subject
        self.private = private
        self.deadline = deadline
        self.environment = environment
        self.observations: list[dict[str, object]] = []
        self.results: dict[str, StageResult] = {}

    def stage_log(self, stage_id: str) -> Path:
        directory = self.private / "logs"
        directory.mkdir(mode=0o700, exist_ok=True)
        return directory / f"{stage_id}.log"

    def stage_evidence(self, stage_id: str) -> Path:
        directory = self.private / "ci-evidence" / stage_id
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        return directory

    def _record(self, *, stage_id: str, command: list[str],
                environment: dict[str, str]) -> StageResult:
        kind = STAGE_KINDS[stage_id]
        log = self.stage_log(stage_id)
        before = snapshot_host()
        started = time.monotonic()
        # A stage that hits its bound still produced a log and still belongs in the
        # record, so both are captured before the failure is propagated.
        try:
            exit_code, duration = run_child(
                command, cwd=self.subject, environment=environment, log=log,
                stage_id=stage_id, deadline=self.deadline)
        except Incomplete:
            duration = round(time.monotonic() - started, 3)
            self.observations.append({
                "stage": stage_id, "kind": kind, "before": before,
                "after": snapshot_host(), "completed": False,
                "command": _normalized_command(command, self.subject),
            })
            self.results[stage_id] = StageResult(
                stage_id, kind, tuple(command), -1, duration, log)
            raise
        after = snapshot_host()
        self.observations.append({
            "stage": stage_id, "kind": kind, "before": before, "after": after,
            "completed": True,
            "command": _normalized_command(command, self.subject),
        })
        result = StageResult(stage_id, kind, tuple(command), exit_code, duration, log)
        self.results[stage_id] = result
        return result

    def check_stage(self, stage_id: str, extra: list[str] | None = None) -> StageResult:
        """Run one stage of the repository's own gate, unmodified."""
        evidence = self.stage_evidence(stage_id)
        options = ["--repo", ".", "--evidence", str(evidence), *(extra or [])]
        script = (
            "set -euo pipefail; . ./scripts/with_sts_cjpm.sh; "
            "exec bash scripts/check.sh " + stage_id + " "
            + " ".join(shlex.quote(option) for option in options)
        )
        return self._record(stage_id=stage_id,
                            command=["bash", "-c", script],
                            environment=self.environment)

    def smoke_stage(self, evidence: Path) -> StageResult:
        environment = dict(self.environment)
        environment["cjHeapSize"] = SMOKE_HEAP
        command = [
            sys.executable, "scripts/real_repository_smoke.py",
            "--binary", str(self.subject / "target/release/bin/main"),
            "--project", ".", "--evidence", str(evidence),
        ]
        return self._record(stage_id="smoke", command=command,
                            environment=environment)

    def perf_stage(self, *, binary: Path, baseline: Path,
                   evidence: Path) -> StageResult:
        environment = dict(self.environment)
        environment["cjHeapSize"] = PERF_HEAP
        command = [
            sys.executable, "scripts/perf_gate.py", "check",
            "--binary", str(binary), "--baseline", str(baseline),
            "--evidence", str(evidence),
        ]
        return self._record(stage_id="perf", command=command,
                            environment=environment)


def _normalized_command(command: list[str], subject: Path) -> list[str]:
    """The command with machine paths replaced, safe for a published summary."""
    return [
        sanitize_detail(str(token).replace(str(subject), "<subject>"))
        for token in command
    ]


def stage_summary(result: StageResult) -> dict[str, object]:
    return {
        "id": result.stage_id,
        "kind": result.kind,
        "status": "passed" if result.exit_code == 0 else "failed",
        "exitCode": result.exit_code,
        "durationSeconds": result.duration_seconds,
        "logBytes": result.log.stat().st_size if result.log.is_file() else 0,
        "logSha256": sha256_file(result.log) if result.log.is_file() else None,
        "command": list(result.command),
    }


# --------------------------------------------------------------------------- #
# Kernel cores
# --------------------------------------------------------------------------- #

def core_spool(output: Path) -> Path:
    """``<output parent>/core-spool``: the private directory the kernel dumps to."""
    return Path(os.path.abspath(os.fspath(output))).parent / "core-spool"


def verify_core_spool(spool: Path) -> dict[str, object]:
    """Confirm this run can write and find a private kernel core.

    The workflow configures ``kernel.core_pattern`` to
    ``<spool>/core.%p.%t``. Both the literal and the resolved spelling of the
    spool directory are accepted so a symlinked temp root still matches.
    """
    require_directory(spool, "private kernel core spool")
    if stat.S_IMODE(spool.lstat().st_mode) != 0o700:
        raise Incomplete("the kernel core spool is not mode 0700")
    if any(True for _entry in spool.iterdir()):
        raise Incomplete("the kernel core spool is not empty before the capture")
    try:
        pattern = Path("/proc/sys/kernel/core_pattern").read_text(
            encoding="utf-8").strip()
    except OSError as error:
        raise Incomplete(f"kernel.core_pattern is unreadable: {error}") from error
    if pattern.startswith("|"):
        raise Incomplete(
            "kernel.core_pattern is a pipe handler, so no private core can be bound")
    directory, _separator, template = pattern.rpartition("/")
    expected = f"{spool}/core.%p.%t"
    matches = pattern == expected
    if not matches and template == "core.%p.%t" and directory:
        try:
            matches = os.path.realpath(directory) == os.path.realpath(spool)
        except OSError:
            matches = False
    if not matches:
        raise Incomplete(
            "kernel.core_pattern is not the private spool template this run needs")
    _soft, hard = resource.getrlimit(resource.RLIMIT_CORE)
    if hard != resource.RLIM_INFINITY:
        raise Incomplete("an unlimited core hard limit is required before the cohort")
    return {
        # Deliberately not the absolute path: this record is published.
        "directory": "output.parent/core-spool",
        "patternTemplate": template,
        "patternMatches": True,
        "hardLimit": "unlimited" if hard == resource.RLIM_INFINITY else int(hard),
    }


def disable_child_core_dumps() -> tuple[int, int]:
    """Keep this run's own soft limit at zero for every ordinary child.

    Precursors and the ``basic`` cohort never write a core; the capability probe
    and the ``self`` launcher raise their own soft limit explicitly.
    """
    soft, hard = resource.getrlimit(resource.RLIMIT_CORE)
    if soft != 0:
        resource.setrlimit(resource.RLIMIT_CORE, (0, hard))
    return 0, hard


def parse_elf_core(path: Path, *, with_digest: bool = True) -> dict[str, object]:
    """Read a kernel core's ELF headers and notes without a debugger.

    The answer covers two things: whether the file is a *complete* core (every
    described segment lies inside the file) and which process wrote it -- its
    ``NT_PRPSINFO`` name and arguments, its PID, its fatal signal and the files it
    had mapped. ``with_digest`` is off while a core is still being written, because
    hashing a multi-gigabyte file on every poll would slow the capture down.
    """
    size = path.stat().st_size
    observed: dict[str, object] = {
        "bytes": size,
        "sha256": None,
        "elf": False,
        "type": None,
        "complete": False,
        "processName": None,
        "processArgs": None,
        "processPid": None,
        "signal": None,
        "mappedFiles": [],
        "notes": [],
    }
    try:
        with path.open("rb", buffering=0) as stream:
            header = stream.read(64)
            if len(header) < 64 or header[:4] != b"\x7fELF":
                observed["notes"].append("not an ELF file")
                return observed
            if header[4] != ELF_CLASS64 or header[5] != ELF_DATA_LSB:
                observed["notes"].append("not a little-endian 64-bit ELF file")
                return observed
            e_type, = struct.unpack_from("<H", header, 16)
            e_phoff, = struct.unpack_from("<Q", header, 32)
            e_phentsize, e_phnum = struct.unpack_from("<HH", header, 54)
            observed["elf"] = True
            observed["type"] = int(e_type)
            if e_type != ELF_ET_CORE:
                observed["notes"].append("not an ELF core file")
                return observed
            if e_phentsize < 56 or e_phnum == 0:
                observed["notes"].append("the program header table is empty")
                return observed
            stream.seek(e_phoff)
            table = stream.read(e_phentsize * e_phnum)
            if len(table) != e_phentsize * e_phnum:
                observed["notes"].append("the program header table is truncated")
                return observed
            segments: list[tuple[int, int, int]] = []
            notes: list[tuple[int, int]] = []
            for index in range(e_phnum):
                base = index * e_phentsize
                p_type, = struct.unpack_from("<I", table, base)
                p_offset, = struct.unpack_from("<Q", table, base + 8)
                p_filesz, = struct.unpack_from("<Q", table, base + 32)
                segments.append((int(p_type), int(p_offset), int(p_filesz)))
                if p_type == 4:  # PT_NOTE
                    notes.append((int(p_offset), int(p_filesz)))
            for _type, offset, filesz in segments:
                if filesz and offset + filesz > size:
                    observed["notes"].append(
                        "a described segment lies past the end of the file")
                    return observed
            if not any(segment[0] == 1 for segment in segments):
                observed["notes"].append("no loadable segment is described")
                return observed
            if not notes:
                observed["notes"].append("the core holds no note segment")
                return observed
            for offset, filesz in notes:
                stream.seek(offset)
                _read_core_notes(stream.read(filesz), observed)
            observed["complete"] = True
    except (OSError, struct.error, ValueError) as error:
        observed["notes"].append(
            "the core is unreadable: " + sanitize_detail(str(error)))
        return observed
    if with_digest and observed["complete"]:
        observed["sha256"] = sha256_file(path)
    return observed


def _read_core_notes(block: bytes, observed: dict[str, object]) -> None:
    offset = 0
    while offset + 12 <= len(block):
        namesz, descsz, note_type = struct.unpack_from("<III", block, offset)
        offset += 12
        name = block[offset:offset + namesz].rstrip(b"\0")
        offset += (namesz + 3) & ~3
        description = block[offset:offset + descsz]
        offset += (descsz + 3) & ~3
        if name != b"CORE":
            continue
        if note_type == NT_PRPSINFO and len(description) >= 136:
            # 64-bit elf_prpsinfo: state/sname/zomb/nice (4 bytes), 4 bytes of
            # alignment, pr_flag (8), uid, gid, pid, ppid, pgrp, sid (4 each,
            # offsets 16..40), pr_fname[16] (40..56), pr_psargs[80] (56..136).
            # fields: 4 state bytes, pr_flag, then uid, gid, pid, ppid, pgrp, sid.
            fields = struct.unpack_from("<4B4xQ6I", description, 0)
            observed["processPid"] = int(fields[7])
            observed["processName"] = description[40:56].rstrip(b"\0").decode(
                "utf-8", "replace")
            observed["processArgs"] = description[56:136].rstrip(b"\0").decode(
                "utf-8", "replace")
        elif note_type == NT_SIGINFO and len(description) >= 12:
            number, _error, _code = struct.unpack_from("<iii", description, 0)
            observed["signal"] = int(number)
        elif note_type == NT_FILE and len(description) >= 16:
            count, _page_size = struct.unpack_from("<QQ", description, 0)
            # Linux NT_FILE has two words followed by count triples and filenames.
            names_start = 16 + int(count) * 24
            if names_start > len(description):
                continue
            entries = min(int(count), MAX_MAPPED_FILES)
            names = description[names_start:].split(b"\0")
            seen: set[str] = set()
            mapped: list[dict[str, object]] = []
            for index in range(entries):
                base = 16 + index * 24
                if base + 24 > len(description) or index >= len(names):
                    break
                start, end, offset_pages = struct.unpack_from("<QQQ", description, base)
                # Kept verbatim: this list is matched against the product binary and
                # only its count ever reaches a published summary.
                rendered = names[index].decode("utf-8", "replace")
                if not rendered or rendered in seen:
                    continue
                seen.add(rendered)
                mapped.append({
                    "path": rendered,
                    "start": int(start),
                    "end": int(end),
                    "fileOffsetPages": int(offset_pages),
                })
            observed["mappedFiles"] = mapped


def wait_for_core(spool: Path, before: set[str], predicate, *, label: str
                  ) -> tuple[Path | None, dict[str, object]]:
    """Wait until a matching spool core is stable, then report it.

    The kernel writes the core while the process dies, so a stable size is what
    separates a complete core from one still being written. A file that never
    settles is reported as unsettled instead of being handed to a debugger.
    """
    deadline = time.monotonic() + CORE_SETTLE_SECONDS
    state: dict[str, object] = {"candidates": 0, "settled": False, "reason": None}
    sizes: dict[str, int] = {}
    while True:
        entries = sorted(
            (entry for entry in spool.iterdir()
             if entry.name not in before and not entry.is_symlink()
             and entry.is_file()),
            key=lambda entry: entry.name, reverse=True)
        state["candidates"] = len(entries)
        settled: list[tuple[float, str, int, Path]] = []
        for entry in entries:
            key = entry.name
            try:
                metadata = entry.stat()
            except OSError:
                continue
            size = metadata.st_size
            if sizes.get(key) == size and size > 0 and predicate(entry, size):
                settled.append((metadata.st_mtime, key, size, entry))
            sizes[key] = size
        if settled:
            # Newest first: if several self invocations left a core, the failed one
            # is the one written last.
            _mtime, _name, size, newest = max(settled)
            state["settled"] = True
            state["bytes"] = size
            state["matched"] = len(settled)
            return newest, state
        if time.monotonic() >= deadline:
            state["reason"] = (
                "no new core file appeared in the private spool" if not entries else
                f"no core file matched the {label} process or a core never settled")
            return None, state
        time.sleep(0.5)


def gdb_path() -> str:
    located = shutil.which("gdb", path="/usr/local/bin:/usr/bin:/bin")
    if located is None:
        raise Incomplete("gdb is not installed")
    return located


def offline_dump(*, core: Path, program: Path, directory: Path, gdb: str,
                 label: str) -> dict[str, object]:
    """Load an already-written core offline and collect frame evidence.

    Nothing here perturbs a measured run: the core exists before this starts.
    The output keeps the newest frame, every thread's stack, the selected frame's
    registers and a bounded header read, and it states plainly when the selected
    frame's memory reads as zeros instead of treating zeros as proof.
    """
    directory.mkdir(mode=0o700, exist_ok=True)
    script = directory / f"{label}.gdb"
    capture = directory / f"{label}.json"
    log = directory / f"{label}-dump.log"
    script.write_text(core_script_text(capture), encoding="utf-8")
    os.chmod(script, 0o600)
    command = [
        gdb, "-q", "-nx", "--batch", str(program), "-c", str(core),
        "-x", str(script),
    ]
    with log.open("xb") as stream:
        os.chmod(log, 0o600)
        try:
            child = subprocess.Popen(
                command, env=minimal_environment("/usr/local/bin:/usr/bin:/bin"),
                cwd=str(directory), stdin=subprocess.DEVNULL, stdout=stream,
                stderr=subprocess.STDOUT, start_new_session=True,
            )
        except OSError as error:
            raise Incomplete(
                f"the offline debugger could not be started: {error}") from error
        try:
            child.wait(timeout=OFFLINE_DUMP_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            os.killpg(os.getpgid(child.pid), signal.SIGKILL)
            raise Incomplete("the offline debugger did not finish")
    summary = summarize_core_dump(log, capture)
    summary["exitCode"] = child.returncode
    summary["logBytes"] = log.stat().st_size if log.is_file() else 0
    counts = summary.get("threadFrameCounts") or {}
    summary["hasAllStacks"] = (
        len(counts) == summary.get("threads") and bool(counts)
        and all(count > 0 for count in counts.values()))
    return summary


def core_capability_proof(*, spool: Path, private: Path,
                          environment: dict[str, str]) -> dict[str, object]:
    """Prove that a complete, debugger-loadable kernel core can be produced here.

    The probe is a separate, clearly labeled, non-product Python abort. Its core is
    deleted afterwards and it is never counted as product fault evidence.
    """
    directory = private / "core-probe"
    directory.mkdir(mode=0o700, exist_ok=True)
    log = directory / "probe.log"
    before = {entry.name for entry in spool.iterdir()}
    program = (
        "import os, resource, sys\n"
        "soft, hard = resource.getrlimit(resource.RLIMIT_CORE)\n"
        "resource.setrlimit(resource.RLIMIT_CORE, (hard, hard))\n"
        "sys.stderr.write('native-gc-core-probe\\n')\n"
        "sys.stderr.flush()\n"
        "os.abort()\n"
    )
    probe_environment = minimal_environment(environment["PATH"])
    for key in ("HOME", "TMPDIR", "TMP", "TEMP"):
        probe_environment[key] = environment[key]
    started = time.monotonic()
    with log.open("xb") as stream:
        os.chmod(log, 0o600)
        child = subprocess.Popen(
            [sys.executable, "-c", program], env=probe_environment,
            stdin=subprocess.DEVNULL, stdout=stream, stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        try:
            exit_code = child.wait(timeout=CORE_PROBE_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            os.killpg(os.getpgid(child.pid), signal.SIGKILL)
            raise Incomplete("the kernel core capability probe did not end")
    pid = child.pid
    prefix = f"core.{pid}."

    def matches(entry: Path, _size: int) -> bool:
        return entry.name.startswith(prefix)

    core, settle = wait_for_core(spool, before, matches, label="capability probe")
    if core is None:
        raise Incomplete(
            "the kernel did not write a usable core for the capability probe: "
            + str(settle.get("reason")))
    observed = parse_elf_core(core)
    if not observed["complete"]:
        raise Incomplete(
            "the capability probe core is not a complete ELF core: "
            + "; ".join(observed["notes"] or ["unknown reason"]))
    if observed.get("processPid") != pid:
        raise Incomplete("the capability probe core belongs to another process")
    if observed.get("signal") != PROBE_SIGNAL:
        raise Incomplete("the capability probe core records an unexpected signal")
    interpreter = Path(sys.executable).name
    expected = interpreter.split(".")[0][:9]
    if not str(observed.get("processName") or "").startswith(expected):
        raise Incomplete("the capability probe core names another program")
    dump = offline_dump(core=core, program=Path(sys.executable),
                        directory=directory, gdb=gdb_path(), label="probe")
    if not dump["loaded"] or not dump["signalNumbers"]:
        raise Incomplete("the debugger could not load the capability probe core")
    receipt: dict[str, object] = {
        "kind": "capture-tool-verification",
        "notProductFaultEvidence": True,
        "probe": {
            "program": "python",
            "deliberateSignal": "SIGABRT",
            "exitCode": exit_code,
            "durationSeconds": round(time.monotonic() - started, 3),
            "coreComplete": True,
            "coreSignal": observed["signal"],
            "processNameMatched": True,
            "debuggerLoaded": True,
            "debuggerThreads": dump["threads"],
            "settle": settle,
        },
        "probeCoreDeleted": False,
        "note": ("a successful probe shows the capture tooling can bind a kernel "
                 "core; it says nothing about the product"),
    }
    try:
        core.unlink()
        receipt["probeCoreDeleted"] = True
    except OSError as error:
        receipt["deleteError"] = sanitize_detail(str(error))
    return receipt


def bind_product_core(*, spool: Path, before: set[str], subject: Path,
                      main_binary: Path, private: Path,
                      attributed: bool) -> dict[str, object]:
    """Find the kernel core of the failed ``self`` main and prove it is that one.

    The measured ``self`` main is a child of ``measure_command.py``; a detached
    worker could crash instead. A core is accepted only when its own notes name the
    product binary, let it be the very file the cohort executed, and map that file.
    A worker core therefore can never be read as the main's.
    """
    if not attributed:
        return {"bound": False, "reason": "the failure log does not identify self"}
    launches = [item for item in read_native_launches(private)
                if item["profile"] == "self"]
    if not launches:
        return {"bound": False, "reason": "no self launch PID was recorded"}
    expected_pid = launches[-1]["pid"]
    directory = private / "core"
    directory.mkdir(mode=0o700, exist_ok=True)
    expected_main = os.path.realpath(main_binary)
    # The launcher execs the product, so its recorded PID is the actual main PID.
    complete: dict[str, tuple[int, dict[str, object]]] = {}

    def parse(entry: Path, size: int) -> dict[str, object]:
        """Parse once per stable size; a growing core is never remembered."""
        cached = complete.get(entry.name)
        if cached is not None and cached[0] == size:
            return cached[1]
        parsed = parse_elf_core(entry, with_digest=False)
        if parsed["complete"]:
            complete[entry.name] = (size, parsed)
        return parsed

    def binds(entry: Path, size: int) -> bool:
        parsed = parse(entry, size)
        if not parsed["complete"]:
            return False
        if parsed.get("processPid") != expected_pid:
            return False
        mapped = [str(item.get("path") or "") for item in parsed.get("mappedFiles", [])
                  if isinstance(item, dict)]
        return expected_main in mapped

    # The window is always spent, because the kernel begins writing a core slightly
    # after the child dies and a signal death reaches this process as exit 245 from
    # measure_command.py rather than as a negative status. Skipping the wait would
    # discard the only fault evidence this capture exists to collect.
    core, settle = wait_for_core(spool, before, binds, label="self invocation")
    receipt: dict[str, object] = {
        "spoolCandidates": settle.get("candidates"),
        "settled": settle.get("settled"),
        "attribution": "self" if attributed else "unattributed",
        "bound": False,
        "reason": None,
    }
    if core is None:
        receipt["reason"] = sanitize_detail(str(
            settle.get("reason") or "no core bound to the failed self invocation"))
        return receipt
    parsed = parse_elf_core(core, with_digest=True)
    signal_number = parsed.get("signal")
    receipt.update({
        "name": core.name,
        "bytes": parsed["bytes"],
        "sha256": parsed["sha256"],
        "complete": parsed["complete"],
        "signal": signal_number,
        "signalName": FAULT_SIGNALS.get(int(signal_number or 0)),
        "processName": parsed.get("processName"),
        "processPid": parsed.get("processPid"),
        "executableMapped": True,
        "mappedFileCount": len(parsed.get("mappedFiles") or []),
        "recordedLaunchPid": expected_pid,
        "argvStoredBytes": len(str(parsed.get("processArgs") or "").encode("utf-8")),
    })
    if signal_number not in FAULT_SIGNALS:
        receipt["reason"] = "the bound core records no fatal signal"
        return receipt
    destination = directory / "core.bin"
    shutil.copyfile(core, destination)
    os.chmod(destination, 0o600)
    if sha256_file(destination) != parsed["sha256"]:
        raise Incomplete("the bound core changed while it was copied")
    receipt["copy"] = {"bytes": destination.stat().st_size,
                       "sha256": sha256_file(destination)}
    receipt["offline"] = offline_dump(
        core=destination, program=main_binary, directory=directory,
        gdb=gdb_path(), label="product")
    if not receipt["offline"]["loaded"] or not receipt["offline"]["hasAllStacks"] \
            or receipt["offline"]["exitCode"] != 0:
        receipt["reason"] = "the bound core could not be fully inspected offline"
        return receipt
    receipt["bound"] = True
    # The verified copy under private/ is the one that gets encrypted; the spool
    # file is removed so no raw core is left outside the ciphertext. A failure to
    # remove it is recorded, not hidden.
    try:
        core.unlink()
        receipt["spoolCopyRemoved"] = True
    except OSError as error:
        receipt["spoolCopyRemoved"] = False
        receipt["spoolRemoveError"] = sanitize_detail(str(error))
    return receipt


# --------------------------------------------------------------------------- #
# Predecessor outputs, fresh-build seal and candidate restore
# --------------------------------------------------------------------------- #

def build_outputs(subject: Path) -> set[str]:
    """Build trees and bytecode directories present in the subject checkout.

    A fixed list of directories would silently miss a fixture that moved; walking
    the tree instead answers the same question the gate's own cleanup asks. The
    walk prunes ``.git`` and the top-level ``target`` (the product's own build tree,
    which the precursor build legitimately owns) so it never mistakes them for a
    stray fixture output.
    """
    found: set[str] = set()
    for current, directories, _files in os.walk(subject, topdown=True):
        relative_current = Path(current).relative_to(subject)
        at_root = relative_current == Path(".")
        keep: list[str] = []
        for name in directories:
            relative = Path(name) if at_root else relative_current / name
            if at_root and name in {".git", "target"}:
                # `.git` is not an output, and the product's own `target/` belongs to
                # the precursor build rather than to a fixture.
                continue
            if name in SWEEP_NAMES:
                found.add(relative.as_posix())
                continue
            keep.append(name)
        directories[:] = keep
    return found


def remove_owned_outputs(subject: Path, relative_paths: set[str]
                         ) -> list[dict[str, str]]:
    """Delete only what this run created, after a type check.

    A path that is not a plain directory is reported instead of being deleted: a
    symlink or an unexpected file could be a user's data that merely looks like an
    output.
    """
    removed: list[dict[str, str]] = []
    for relative in sorted(relative_paths):
        path = subject / relative
        try:
            metadata = path.lstat()
        except FileNotFoundError:
            continue
        kind = "bytecode" if path.name in BYTECODE_NAMES else "build-tree"
        if stat.S_ISLNK(metadata.st_mode):
            removed.append({"path": relative, "kind": kind,
                            "action": "left symlink in place"})
            continue
        if not stat.S_ISDIR(metadata.st_mode):
            raise Incomplete(
                "an owned output is not a directory, so it is not deleted")
        shutil.rmtree(path)
        removed.append({"path": relative, "kind": kind, "action": "removed"})
    return removed


def seal_and_restore(*, subject: Path, private: Path,
                     extracted: dict[str, dict[str, object]]) -> dict[str, object]:
    """Keep the fresh build's receipt privately, then put the recovered product back.

    The recovered candidate remains the tested product. The fresh build's manifest
    is preserved as its own receipt and is never written over the recovered one;
    consumers read the recovered historical manifest byte-for-byte, so no
    provenance is fabricated.

    The fresh binaries themselves are not retained -- they would add tens of
    megabytes to the ciphertext for no evidence the digests do not already carry.
    Their sizes and SHA-256 values, plus the byte-equality verdict against the
    recovered candidate, are what the receipt states.
    """
    sealed = private / "fresh-build"
    sealed.mkdir(mode=0o700, exist_ok=True)
    main_target = subject / "target/release/bin/main"
    worker_target = subject / "target/release/bin/chir-worker-main"
    manifest_target = subject / "target/ci-build/build-manifest.json"
    for path in (main_target, worker_target, manifest_target):
        require_regular_file(path, f"fresh build output {path.name}")
    fresh_manifest = sealed / "build-manifest.json"
    shutil.copyfile(manifest_target, fresh_manifest)
    os.chmod(fresh_manifest, 0o600)
    fresh_value = json.loads(fresh_manifest.read_text(encoding="utf-8"))
    identity = {
        "main": file_identity(main_target),
        "worker": file_identity(worker_target),
        "buildManifest": file_identity(fresh_manifest),
        "buildManifestValue": fresh_value,
    }
    private_json(sealed / "identity.json", identity)
    recovered_root = private / "candidates/recovered"
    for relative in (
        "target/release/bin/main",
        "target/release/bin/chir-worker-main",
        "target/ci-build/build-manifest.json",
    ):
        destination = subject / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(recovered_root / relative, destination)
        if destination.is_symlink():
            raise Incomplete("a restored candidate destination is a symlink")
        os.chmod(destination, 0o755 if "/bin/" in relative else 0o644)
    for relative, expected in extracted.items():
        if file_identity(subject / relative)["sha256"] != expected["sha256"]:
            raise Incomplete(
                "a restored candidate file does not match its recovered bytes")

    comparison = {
        "freshBuildMain": identity["main"],
        "freshBuildWorker": identity["worker"],
        "recoveredMain": extracted["target/release/bin/main"],
        "recoveredWorker": extracted["target/release/bin/chir-worker-main"],
        "mainBytesIdentical": identity["main"]["sha256"]
        == extracted["target/release/bin/main"]["sha256"],
        "workerBytesIdentical": identity["worker"]["sha256"]
        == extracted["target/release/bin/chir-worker-main"]["sha256"],
        "freshBuildRunId": fresh_value.get("runId"),
        "freshBuildRunAttempt": fresh_value.get("runAttempt"),
        "recoveredRunId": CANDIDATE_RUN_ID,
        "consumersUseRecoveredBinaries": True,
        "consumersUseRecoveredManifest": True,
        "recoveredManifestUnmodified": True,
        "freshBuildReceiptIsDiagnosticOnly": True,
    }
    return {"identity": identity, "comparison": comparison,
            "manifest": fresh_manifest,
            "identityPath": sealed / "identity.json"}


# --------------------------------------------------------------------------- #
# Read-only release prechecks
# --------------------------------------------------------------------------- #

def release_prechecks(*, subject: Path, environment: dict[str, str],
                      private: Path) -> dict[str, object]:
    """Read-only checks of the original source release inputs.

    These report what the original job's inputs are. They never publish a release
    receipt, never move a tag and never claim this branch is a Release.
    """
    result: dict[str, object] = {
        "tag": RELEASE_TAG,
        "commit": SUBJECT_COMMIT,
        "releaseClaim": False,
        "status": "unknown",
        "detail": None,
        "buildParameters": None,
    }
    git_environment = minimal_environment(environment["PATH"])
    git_environment["HOME"] = environment["HOME"]
    tag_run = run_checked(
        ["git", "-C", str(subject), "rev-parse", "--verify",
         f"refs/tags/{RELEASE_TAG}^{{commit}}"],
        env=git_environment, timeout=120)
    if tag_run.returncode != 0:
        result["status"] = "tagUnavailable"
        result["detail"] = (
            "the release tag is not present in this checkout, so no release "
            "identity is asserted for this branch")
    else:
        resolved = tag_run.stdout.strip()
        result["tagCommit"] = resolved
        if resolved != SUBJECT_COMMIT:
            result["status"] = "tagPointsElsewhere"
            result["detail"] = "the release tag does not point at the frozen subject"
        else:
            completed = run_checked(
                [sys.executable, str(subject / "scripts/verify_release.py"),
                 "--repo", str(subject), "--tag", RELEASE_TAG,
                 "--expected-commit", SUBJECT_COMMIT],
                env=environment, timeout=600)
            log = private / "logs/precheck.log"
            log.write_text(completed.stdout + completed.stderr, encoding="utf-8")
            os.chmod(log, 0o600)
            result["status"] = "verified" if completed.returncode == 0 else "failed"
            if completed.returncode != 0:
                result["detail"] = sanitize_detail(
                    (completed.stderr or completed.stdout).strip()[-1000:])

    parameters = run_checked(
        [sys.executable, str(subject / "scripts/release_build_parameters.py"),
         "--repo", str(subject), "--platform", "linux-x64"],
        env=environment, timeout=900)
    parameters_log = private / "logs/precheck-build-parameters.log"
    parameters_log.write_text(parameters.stdout + parameters.stderr,
                              encoding="utf-8")
    os.chmod(parameters_log, 0o600)
    if parameters.returncode != 0:
        result["buildParameters"] = {"status": "failed", "observed": None}
        if result["status"] in {"unknown", "verified"}:
            result["status"] = "buildParametersFailed"
        result["detail"] = sanitize_detail(
            (parameters.stderr or parameters.stdout).strip()[-1000:])
        return result
    observed = None
    try:
        observed = json.loads(parameters.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        observed = None
    result["buildParameters"] = {
        "status": "observed",
        "effectiveCompileOption": observed.get("effectiveCompileOption")
        if isinstance(observed, dict) else None,
        "wrapperSha256": observed.get("wrapperSha256")
        if isinstance(observed, dict) else None,
    }
    if result["status"] == "unknown":
        result["status"] = "buildParametersObserved"
    return result


def require_release_prechecks(prechecks: dict[str, object]) -> None:
    """Fail closed when the source release inputs do not hold.

    The original tag and build parameters must both match the frozen inputs;
    checking them does not turn this diagnostic branch into a release.
    """
    status = prechecks.get("status")
    if status != "verified":
        raise Incomplete(
            "the read-only release precheck failed ("
            f"{status}): {prechecks.get('detail') or 'no detail'}")


# --------------------------------------------------------------------------- #
# Input drift
# --------------------------------------------------------------------------- #

def verify_inputs_unchanged(*, subject: Path, candidate_root: Path,
                            extracted: dict[str, dict[str, object]],
                            native_directory: Path,
                            before: dict[str, object]) -> None:
    after = subject_identity(subject, "the subject checkout after the replay")
    for key in ("headCommit", "tree", "worktreeSha256"):
        if after[key] != before[key]:
            raise Incomplete("the subject worktree changed during the replay")
    for member, expected in extracted.items():
        if sha256_file(candidate_root / member) != expected["sha256"]:
            raise Incomplete("a recovered candidate file changed during the replay")
    for name, _bytes, expected_sha in NATIVE_LIBRARIES:
        if sha256_file(native_directory / name) != expected_sha:
            raise Incomplete("a pinned SDK native library changed during the replay")


def record_post_state(manifest: dict[str, object], state: dict[str, object] | None
                      ) -> None:
    """State whether this run's own inputs survived, without ever assuming."""
    if state is None:
        manifest["postRun"] = {"sourceUnchanged": None, "binaryUnchanged": None,
                               "sdkUnchanged": None}
        return
    try:
        verify_inputs_unchanged(
            subject=state["subject"], candidate_root=state["candidateRoot"],
            extracted=state["extracted"],
            native_directory=state["nativeDirectory"], before=state["before"])
        verify_sdk(state["sdkRoot"], state["sidecar"], state["compilerEnvironment"])
        if state.get("consumerInstalled"):
            for member, expected in state["extracted"].items():
                if file_identity(state["subject"] / member) != expected:
                    raise Incomplete("a consumed candidate file changed during the replay")
        if sha256_file(state["mainBinary"]) != CANDIDATE_MEMBERS[
                "target/release/bin/main"]["sha256"]:
            raise Incomplete("the recovered candidate binary changed")
    except (Incomplete, OSError) as error:
        manifest["postRun"] = {
            "sourceUnchanged": None, "binaryUnchanged": None,
            "sdkUnchanged": None, "inputsVerified": False,
            "inputVerificationError": sanitize_detail(str(error)),
        }
        return
    manifest["postRun"] = {
        "sourceUnchanged": True,
        "binaryUnchanged": True if state.get("consumerInstalled") else None,
        "recoveredBinaryUnchanged": True, "sdkUnchanged": True,
        "inputsVerified": bool(state.get("consumerInstalled")),
    }


# --------------------------------------------------------------------------- #
# Reporting
# --------------------------------------------------------------------------- #

def _or_absent(value: object) -> str:
    """A published field is either a real value or the word absent, never blank."""
    return str(value) if value not in (None, "") else "absent"


def diagnosis_text(manifest: dict[str, object]) -> str:
    subject = manifest["subject"]
    candidate = manifest["candidate"]
    precursor = manifest["precursor"]
    capability = manifest["coreCapability"]
    capture = manifest["capture"]
    assert isinstance(subject, dict) and isinstance(candidate, dict)
    assert isinstance(precursor, dict) and isinstance(capability, dict)
    assert isinstance(capture, dict)
    toolchain = manifest.get("toolchain")
    lines = [
        "cjdoc native GC original-context replay",
        "=" * 38,
        "",
        "This run is diagnostic evidence only. It is not an acceptance gate, not a",
        "release retry and not a fix. A completed collection -- including a clean",
        "run -- does not mean the observed failure is understood or fixed.",
        "",
        f"workflow revision : {manifest['workflowSha']}",
        f"workflow run      : {manifest['workflowRun']['runId']}"
        f" attempt {manifest['workflowRun']['runAttempt']}",
        f"subject commit    : {subject['commit']}",
        f"subject tree      : {subject['tree']}",
        f"candidate archive : {candidate['tarSha256']} ({candidate['tarBytes']} bytes)",
        f"candidate origin  : artifact {candidate['artifactId']} of run"
        f" {candidate['runId']} attempt {candidate['runAttempt']}",
        f"main binary       : {candidate['main']['sha256']}",
        f"worker binary     : {candidate['worker']['sha256']}",
    ]
    if isinstance(toolchain, dict):
        lines.extend([
            f"toolchain         : Cangjie {toolchain['sdkVersion']} STS + static stdx",
            f"fingerprint       : {toolchain['fingerprint']}",
            f"stdx digest       : {toolchain['stdxDigest']}",
        ])
    lines.extend([
        "",
        "precursor workload (the original Release order, not a new product)",
    ])
    for stage in precursor.get("stages", []):
        if not isinstance(stage, dict):
            continue
        lines.append(
            f"  {stage['id']:<13} {stage['status']:<7} exit {stage['exitCode']:>4}"
            f"  {stage['durationSeconds']:>9.3f}s")
    comparison = precursor.get("identityComparison")
    if isinstance(comparison, dict):
        lines.append(
            "  fresh build vs recovered candidate: main identical "
            f"{'yes' if comparison['mainBytesIdentical'] else 'no'}, worker identical "
            f"{'yes' if comparison['workerBytesIdentical'] else 'no'}")
        lines.append(
            "  consumers ran the recovered binaries and the recovered historical"
            " manifest")
    probe = capability.get("probe")
    if isinstance(probe, dict) and isinstance(probe.get("probe"), dict):
        observed = probe["probe"]
        lines.append(
            "  kernel core probe: complete core, debugger load "
            f"{'yes' if observed['debuggerLoaded'] else 'no'}"
            " (capture tooling only, never product fault evidence)")
    prechecks = manifest.get("releasePrechecks")
    if isinstance(prechecks, dict):
        lines.append(
            f"  release precheck  : {prechecks['status']}"
            " (read-only; no release receipt is written)")
    lines.extend([
        "",
        f"outcome           : {capture['outcome']}",
        f"complete          : {'yes' if capture['complete'] else 'no'}",
        f"capture status    : {manifest['status']}"
        " (0 collected cleanly, 11 fault captured, 2 incomplete)",
        f"collector exit    : {manifest['collectorExitCode']}"
        " (0 means collection completed; see the status)",
        "",
    ])
    if capture.get("detail"):
        lines.extend([f"detail            : {capture['detail']}", ""])
    failure = capture.get("stageFailure")
    if isinstance(failure, dict):
        invocation = failure.get("invocation") or {}
        lines.append(
            f"failed stage      : {failure['stage']} (exit {failure['exitCode']})")
        if isinstance(invocation, dict) and invocation.get("identified"):
            lines.append(
                "failed invocation : project "
                f"{invocation.get('project') or 'unknown'}, variant"
                f" {invocation.get('variant') or 'unknown'}, measured by"
                " measure_command.py"
                f" {'yes' if invocation.get('measuresCommandWrapper') else 'no'}")
        lines.append("")
    if capture["faultObserved"]:
        core = capture.get("core") or {}
        lines.append(
            "fault observed    : yes"
            f" ({core.get('signalName') or 'signal'} {core.get('signal')})")
        lines.append(
            f"bound core        : {core.get('bytes')} bytes, complete"
            f" {core.get('complete')}, process {core.get('processName')}")
        offline = core.get("offline") if isinstance(core, dict) else None
        if isinstance(offline, dict):
            lines.append(
                "offline frame     : "
                f"{offline.get('selectedFrameName')} (thread"
                f" {offline.get('selectedThread')}, index"
                f" {offline.get('selectedFrameIndex')}, newest"
                f" {offline.get('newestFrameName')})")
            if offline.get("handlerFrameAtTop"):
                lines.append(
                    "                    : a signal-handler frame was skipped and the"
                    " innermost GetSize frame selected first")
            if offline.get("zeroBytesAtRdi"):
                lines.append(
                    "                    : the selected frame's RDI memory reads as"
                    " zeros; zeros alone are not lifecycle proof and may be a sparse"
                    " core region")
        lines.append(
            "next step         : read the decrypted private payload; this summary does"
            " not name a cause")
        lines.append("")
    elif capture["complete"]:
        lines.append("fault observed    : no")
        lines.append(
            "next step         : record a clean observation; the original failure"
            " remains open")
        lines.append("")
    evidence = manifest["evidence"]
    lines.extend([
        "Time and RSS in this cohort are instrumented diagnostic measurements, not",
        "release acceptance; the original budgets, baselines and heap settings are",
        "unchanged.",
        "",
        "No raw stage log, core, offline dump or environment is in this public set.",
        "The complete payload is in private-evidence.p7m and can only be read with",
        "the corresponding private key.",
        "",
        "evidence bundle   : private-evidence.p7m",
        "ciphertext sha256 : "
        f"{_or_absent(evidence['ciphertextSha256'])}",
        f"certificate sha256: {evidence['certificateSha256']}",
        "",
    ])
    if capture["faultObserved"]:
        lines.append(
            "A captured fault is preserved even though the collection completed.")
    elif capture["complete"]:
        lines.append(
            "A completed collection records what the product actually did.")
    else:
        lines.append(
            "This collection is incomplete; the first failure above stands and the")
        lines.append("original failure remains open.")
    lines.append(
        "No capture outcome replaces the original release acceptance gate.")
    return "\n".join(lines) + "\n"


def write_public(output: Path, manifest: dict[str, object], diagnosis: str) -> None:
    public = output / "public"
    public.mkdir(mode=0o700, exist_ok=True)
    (public / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(public / "manifest.json", 0o644)
    (public / "diagnosis.txt").write_text(diagnosis, encoding="utf-8")
    os.chmod(public / "diagnosis.txt", 0o644)


# --------------------------------------------------------------------------- #
# Narrow cohort adapter
# --------------------------------------------------------------------------- #

def write_self_core_launcher(*, private: Path, main_binary: Path,
                             subject: Path) -> Path:
    """Write the pass-through launcher that enables cores for ``self`` only.

    ``perf_gate.py`` runs one binary for both profiles and must not be edited, so
    the narrowest adapter that satisfies "enable RLIMIT_CORE only for the actual
    self subprocesses" is a launcher that inspects the original argument vector,
    raises only its own *soft* core limit to the existing hard limit when the
    project is the subject, and then ``exec``s the real candidate with that same
    vector. Because ``exec`` replaces the image there is still exactly one child
    process: no extra pid, no extra copy, and ``measure_command.py``'s child
    accounting, timing, exit status (including death by signal) and every argument
    are unchanged. It prints nothing and measures nothing.

    A POSIX ``sh`` launcher is deliberate: its startup is a few milliseconds against
    the cohort's second-scale budgets, and for every ``basic`` invocation it changes
    no limit at all -- it walks the argument vector, finds no subject project and
    execs. That startup cost is the only difference from the original executor, and
    the published limitations state it.
    """
    shell = shutil.which("sh", path="/usr/local/bin:/usr/bin:/bin")
    if shell is None:
        raise Incomplete("sh is not installed, so the cohort launcher cannot run")
    directory = private / "launcher"
    directory.mkdir(mode=0o700, exist_ok=True)
    launcher = directory / "self-core-exec"
    program = (
        f"#!{shell}\n"
        "set -eu\n"
        "# Generated by native_gc_context_replay.py. Pass-through exec only.\n"
        "# Raises this process's soft core limit for the self project, then execs.\n"
        f"main_binary={shlex.quote(str(main_binary))}\n"
        f"self_project={shlex.quote(os.path.abspath(subject))}\n"
        "core_self=0\n"
        "wanted=0\n"
        'for argument in "$@"; do\n'
        '  if [ "$wanted" = 1 ]; then\n'
        '    if [ "$argument" = "$self_project" ]; then\n'
        "      core_self=1\n"
        "    fi\n"
        "    wanted=0\n"
        '  elif [ "$argument" = "--project" ]; then\n'
        "    wanted=1\n"
        "  fi\n"
        "done\n"
        'if [ "$core_self" = 1 ]; then\n'
        "  ulimit -S -c unlimited\n"
        "  core_verified=0\n"
        "  while read -r first second third fourth soft hard units; do\n"
        '    if [ "$first $second $third $fourth" = "Max core file size" ]; then\n'
        '      if [ "$soft" != unlimited ]; then\n'
        "        printf '%s\\n' 'core limit was not applied; no sample started' >&2\n"
        "        exit 2\n"
        "      fi\n"
        "      core_verified=1\n"
        "      break\n"
        "    fi\n"
        "  done < /proc/self/limits\n"
        '  [ "$core_verified" = 1 ] || exit 2\n'
        "fi\n"
        "profile=basic\n"
        '[ "$core_self" = 0 ] || profile=self\n'
        f'printf "%s\\t%s\\n" "$profile" "$$" >> {shlex.quote(str(directory / "invocations.tsv"))}\n'
        'exec "$main_binary" "$@"\n'
    )
    launcher.write_text(program, encoding="utf-8")
    os.chmod(launcher, 0o700)
    return launcher


def read_native_launches(private: Path) -> list[dict[str, object]]:
    path = private / "launcher/invocations.tsv"
    if not path.is_file():
        return []
    result = []
    for line in path.read_text(encoding="utf-8").splitlines():
        fields = line.split("\t")
        if len(fields) != 2 or fields[0] not in ("basic", "self") \
                or not fields[1].isdigit():
            raise Incomplete("the native invocation PID record is malformed")
        result.append({"profile": fields[0], "pid": int(fields[1])})
    return result


def failing_invocation(log: Path, subject: Path) -> dict[str, object]:
    """Which original invocation failed, taken from the stage's own log.

    ``perf_gate.py`` writes the failing command into its error text; nothing is
    inferred beyond what that log states.
    """
    try:
        text = log.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return {"identified": False, "reason": "the stage log is unreadable"}
    position = text.rfind("command failed (")
    if position < 0:
        return {"identified": False, "reason": "the log names no failing command"}
    excerpt = text[position:position + 2000]
    match = re.search(r"command failed \((-?\d+)\)", excerpt)
    project_match = re.search(r"--project\s+(\S+)", excerpt)
    project = project_match.group(1) if project_match else None
    variant = None
    for candidate in ("cold", "warm"):
        if f"-{candidate}" in excerpt:
            variant = candidate
            break
    return {
        "identified": True,
        "exitCode": int(match.group(1)) if match else None,
        "project": "." if project in {
            str(subject), os.path.abspath(subject), os.path.realpath(subject),
        } else None,
        "variant": variant,
        "measuresCommandWrapper": "measure_command.py" in excerpt,
        "detail": sanitize_detail(excerpt[:600]),
    }


# --------------------------------------------------------------------------- #
# Entry point
# --------------------------------------------------------------------------- #

def parse_arguments(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Replay the original Linux Release precursor workload, then run the "
            "performance cohort natively with private kernel cores. Publish "
            "encrypted diagnostic evidence. Not an acceptance gate."),
    )
    parser.add_argument("--subject", required=True, type=Path,
                        help="exact frozen subject checkout at its Git top-level")
    parser.add_argument("--candidate-tar", required=True, type=Path,
                        help="frozen candidate archive with the recovered binaries")
    parser.add_argument("--sdk-root", required=True, type=Path,
                        help="installed pinned SDK root (the one envsetup.sh belongs to)")
    parser.add_argument("--certificate", required=True, type=Path,
                        help="committed public encryption certificate")
    parser.add_argument("--output", required=True, type=Path,
                        help="fresh directory that receives public/ and private/")
    parser.add_argument("--workflow-sha", required=True,
                        help="revision of the diagnostic branch that runs this file")
    parser.add_argument("--run-id", required=True,
                        help="workflow run identifier of this capture")
    parser.add_argument("--run-attempt", required=True,
                        help="workflow run attempt of this capture")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    arguments = parse_arguments(argv)
    if not COMMIT.fullmatch(arguments.workflow_sha):
        raise SystemExit("--workflow-sha must be a full 40-character commit id")
    if not DIGITS.fullmatch(arguments.run_id):
        raise SystemExit("--run-id must be numeric")
    if not DIGITS.fullmatch(arguments.run_attempt):
        raise SystemExit("--run-attempt must be numeric")
    if not sys.platform.startswith("linux"):
        raise SystemExit("this kernel-core capture is written for Linux only")

    started_at = utc_now()
    deadline = time.monotonic() + WORKFLOW_DEADLINE_SECONDS
    output = Path(os.path.abspath(os.fspath(arguments.output)))
    if output.is_symlink() or output.exists():
        raise SystemExit("--output must be a fresh, non-existent directory")
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    os.chmod(output, 0o700)
    private = output / "private"
    private.mkdir(mode=0o700)
    for name in ("home", "tmp", "runner-temp", "candidates", "logs"):
        (private / name).mkdir(mode=0o700)
    spool = core_spool(output)
    core_soft, core_hard = disable_child_core_dumps()

    manifest: dict[str, object] = {
        "schemaVersion": SCHEMA,
        "kind": KIND,
        "notAcceptance": True,
        "acceptanceClaim": False,
        "distinctFrom": (
            "cjdoc.native-gc-diagnosis/1 single-shot capture, which remains usable"),
        "workflowSha": arguments.workflow_sha,
        "workflowRun": {"runId": arguments.run_id,
                        "runAttempt": arguments.run_attempt},
        "subject": {"commit": SUBJECT_COMMIT, "tree": SUBJECT_TREE,
                    "worktreeSha256": None, "pathRelative": "."},
        "candidate": {
            "repository": CANDIDATE_REPOSITORY,
            "runId": CANDIDATE_RUN_ID,
            "runAttempt": CANDIDATE_ATTEMPT,
            "artifactId": CANDIDATE_ARTIFACT_ID,
            "tarName": CANDIDATE_TAR_NAME,
            "tarBytes": CANDIDATE_TAR_BYTES,
            "tarSha256": CANDIDATE_TAR_SHA256,
            "main": dict(CANDIDATE_MEMBERS["target/release/bin/main"]),
            "worker": dict(CANDIDATE_MEMBERS["target/release/bin/chir-worker-main"]),
            "buildManifest": None,
            "version": CANDIDATE_VERSION_OUTPUT,
        },
        "runtimeLimits": {
            "coreSoftLimit": core_soft,
            "coreHardLimit": ("unlimited" if core_hard == resource.RLIM_INFINITY
                              else int(core_hard)),
            "childCoreDumps": "disabled for precursors and the basic cohort",
            "selfCoreDumps": "enabled in the self pass-through launcher only",
        },
        "runtimeRecipe": {
            "precursorHeap": PERF_HEAP,
            "perfHeap": PERF_HEAP,
            "smokeHeap": SMOKE_HEAP,
            "gcThreshold": "default",
            "gcInterval": "default",
            "backupGcInterval": "default",
            "jobs": JOBS,
            "cpu": None,
            "perfCycles": None,
            "perfOrder": ["cold", "warm", "warm", "cold"],
            "profiles": ["basic", "self"],
            "deadlineSeconds": WORKFLOW_DEADLINE_SECONDS,
        },
        "releasePrechecks": None,
        "coreCapability": {"required": True, "supported": False, "spool": None,
                           "probe": None},
        "precursor": {
            "purpose": ("the original Release precursor workload, kept only as the "
                        "context the original job created"),
            "stages": [],
            "freshBuild": None,
            "identityComparison": None,
            "outputSweep": None,
        },
        "cohort": {
            "native": True,
            "prewarm": True,
            "order": ["cold", "warm", "warm", "cold"],
            "executor": "original perf_gate.py with original measure_command.py",
            "liveDebugger": False,
            "basicInvocations": 0,
            "selfInvocations": 0,
            "plannedBasicInvocations": 5,
            "plannedSelfInvocations": 5,
            "invocationAccounting": "one prewarm plus cold,warm,warm,cold per profile",
            "coreSelection": "private kernel core per self invocation",
            "budgetsUnchanged": True,
            "baselineUnchanged": True,
            "measurementIsNotAcceptance": True,
            "launcher": None,
            "verdictIsAcceptance": False,
        },
        "capture": {
            "outcome": "incomplete",
            "complete": False,
            "faultObserved": False,
            "signal": None,
            "core": None,
            "stageFailure": None,
            "detail": None,
        },
        "evidence": {
            "certificateSha256": CERTIFICATE_SHA256,
            "ciphertextSha256": None,
            "ciphertextBytes": None,
            "archiveBytes": None,
            "archiveSha256": None,
            "members": [],
            "cipher": "openssl cms -encrypt -binary -aes256 -outform DER",
        },
        "postRun": None,
        "status": EXIT_INCOMPLETE,
        "collectorExitCode": EXIT_INCOMPLETE,
        "startedAt": started_at,
        "finishedAt": None,
        "limitations": [
            "instrumented durability is not release acceptance",
            "original budgets, baselines, heap settings and stage order are unchanged",
            "a clean replay does not show the original failure is fixed",
            "a fault without a complete core bound to self is incomplete, not collected",
            ("the performance cohort runs through a pass-through core-limit launcher, "
             "so its timings include shell startup the original executor did not have"),
            ("zero bytes, including sparse-core holes, do not establish whether "
             "an object was initialized, cleared, freed or overwritten"),
        ],
    }
    subject_record = manifest["subject"]
    candidate_record = manifest["candidate"]
    recipe = manifest["runtimeRecipe"]
    capture = manifest["capture"]
    precursor = manifest["precursor"]
    capability = manifest["coreCapability"]
    cohort = manifest["cohort"]
    assert isinstance(subject_record, dict) and isinstance(candidate_record, dict)
    assert isinstance(recipe, dict) and isinstance(capture, dict)
    assert isinstance(precursor, dict) and isinstance(capability, dict)
    assert isinstance(cohort, dict)

    payloads: list[tuple[str, Path]] = []
    input_state: dict[str, object] | None = None
    replay: Replay | None = None
    status = EXIT_INCOMPLETE

    try:
        # -- frozen inputs --------------------------------------------------- #
        subject = require_directory(
            Path(os.path.abspath(os.fspath(arguments.subject))), "subject checkout")
        # One physical spelling only: the STS wrapper decides whether to patch the
        # manifest by comparing `$PWD` with `$GITHUB_WORKSPACE`, and a symlinked
        # temp root would otherwise let a build run with the declared, empty
        # override instead of the pinned one.
        subject = Path(os.path.realpath(subject))
        identity = subject_identity(subject, "the subject checkout")
        if identity["tree"] != SUBJECT_TREE:
            raise Incomplete("the subject tree differs from the frozen subject")
        before_identity = {
            "headCommit": identity["headCommit"],
            "tree": identity["tree"],
            "worktreeSha256": identity["worktreeSha256"],
        }
        subject_record["worktreeSha256"] = identity["worktreeSha256"]

        archive = require_regular_file(
            Path(os.path.abspath(os.fspath(arguments.candidate_tar))),
            "candidate archive")
        if archive.stat().st_size != CANDIDATE_TAR_BYTES:
            raise Incomplete("the candidate archive size differs from the pin")
        if sha256_file(archive) != CANDIDATE_TAR_SHA256:
            raise Incomplete("the candidate archive digest differs from the pin")
        candidate_root = private / "candidates/recovered"
        candidate_root.mkdir(mode=0o700, exist_ok=True)
        extracted: dict[str, dict[str, object]] = {}
        extract_candidate(archive, candidate_root, extracted)
        main_binary = candidate_root / "target/release/bin/main"
        build_manifest = verify_build_manifest(
            candidate_root / "target/ci-build/build-manifest.json")
        candidate_record["buildManifest"] = build_manifest

        certificate = require_regular_file(
            Path(os.path.abspath(os.fspath(arguments.certificate))),
            "public encryption certificate")
        if sha256_file(certificate) != CERTIFICATE_SHA256:
            raise Incomplete("the encryption certificate differs from the pin")
        if b"PRIVATE KEY" in certificate.read_bytes():
            raise Incomplete("the encryption input must not be a private key")

        sdk_root = Path(os.path.abspath(os.fspath(arguments.sdk_root)))
        sidecar_text = os.environ.get("CANGJIE_STDX_PATH", "")
        if not sidecar_text:
            raise Incomplete(
                "the authenticated static stdx sidecar was not supplied by the SDK wrapper")
        sidecar = Path(os.path.abspath(sidecar_text))
        compiler_environment = minimal_environment(os.pathsep.join([
            str(sdk_root / "bin"), str(sdk_root / "tools" / "bin"),
            str(Path(sys.executable).parent), "/usr/local/bin", "/usr/bin", "/bin",
        ]))
        compiler_environment.update({
            "CANGJIE_HOME": str(sdk_root),
            "CANGJIE_SDK_ROOT": str(sdk_root),
            "CJDOC_PYTHON": sys.executable,
            "HOME": str(private / "home"),
            "TMPDIR": str(private / "tmp"),
            "TMP": str(private / "tmp"),
            "TEMP": str(private / "tmp"),
        })
        sdk = verify_sdk(sdk_root, sidecar, compiler_environment)
        native_directory = sdk["nativeDirectory"]
        tools_directory = sdk["toolsDirectory"]
        assert isinstance(native_directory, Path) and isinstance(tools_directory, Path)
        verify_ldd(main_binary, sdk, {
            **compiler_environment,
            "LD_LIBRARY_PATH": os.pathsep.join(
                [str(native_directory), str(tools_directory)]),
        })
        manifest["toolchain"] = {
            "sdkVersion": sdk["sdkVersion"],
            "target": sdk["target"],
            "fingerprint": sdk["fingerprint"],
            "stdxDigest": sdk["stdxDigest"],
            "cjcSha256": sdk["cjcSha256"],
            "llcSha256": sdk["llcSha256"],
            "nativeLibraries": [
                {"name": name, "bytes": bytes_, "sha256": sha}
                for name, bytes_, sha in NATIVE_LIBRARIES
            ],
            "lddResolved": True,
        }
        # The original Release job exported cjHeapSize=512MB to every step, so the
        # precursor workload inherits exactly that; the smoke stage overrides it to
        # its own 2GB recipe and the performance cohort keeps 512MB.
        environment = child_environment(
            private, subject, sdk_root, sidecar, sdk, heap=PERF_HEAP,
            run_id=arguments.run_id, run_attempt=arguments.run_attempt)
        version_run = run_checked(
            [str(main_binary), "--version"], env=environment, timeout=120)
        if version_run.returncode != 0:
            raise Incomplete("the recovered binary did not report its version")
        if CANDIDATE_VERSION_OUTPUT not in (
                version_run.stdout + version_run.stderr).splitlines():
            raise Incomplete("the recovered binary is not the frozen release")

        for tool in ("git", "bash", "openssl", "taskset"):
            if shutil.which(tool, path=environment["PATH"]) is None:
                raise Incomplete(f"{tool} is not installed")
        gdb_path()
        cpu = minimum_allowed_cpu()
        recipe["cpu"] = cpu
        input_state = {
            "subject": subject,
            "before": before_identity,
            "candidateRoot": candidate_root,
            "extracted": extracted,
            "nativeDirectory": native_directory,
            "mainBinary": main_binary,
            "sdkRoot": sdk_root, "sidecar": sidecar,
            "compilerEnvironment": compiler_environment,
            "consumerInstalled": False,
        }

        # -- capture capability before any workload --------------------------- #
        capability["spool"] = verify_core_spool(spool)
        capability["probe"] = core_capability_proof(
            spool=spool, private=private, environment=environment)
        capability["supported"] = True

        # -- read-only release prechecks -------------------------------------- #
        manifest["releasePrechecks"] = release_prechecks(
            subject=subject, environment=environment, private=private)
        require_release_prechecks(manifest["releasePrechecks"])

        # -- original precursor workload -------------------------------------- #
        preexisting = build_outputs(subject)
        if preexisting:
            raise Incomplete(
                "the subject checkout already holds build trees or bytecode "
                "directories this run did not create, and they will not be deleted: "
                + ", ".join(sorted(preexisting)[:5]))
        replay = Replay(subject=subject, private=private, deadline=deadline,
                        environment=environment)

        check = replay.check_stage("preflight")
        if check.exit_code != 0:
            capture["stageFailure"] = {
                "stage": "preflight", "exitCode": check.exit_code,
                "invocation": {"identified": False,
                               "reason": "the stage log is the evidence"},
            }
            raise Incomplete("the original preflight stage failed")

        build = replay.check_stage("build", [
            "--main-binary-out", "target/release/bin/main",
            "--worker-binary-out", "target/release/bin/chir-worker-main",
            "--manifest", "target/ci-build/build-manifest.json",
        ])
        if build.exit_code != 0:
            capture["stageFailure"] = {
                "stage": "build", "exitCode": build.exit_code,
                "invocation": {"identified": False,
                               "reason": "the stage log is the evidence"},
            }
            raise Incomplete("the precursor build stage failed")

        sealed = seal_and_restore(
            subject=subject, private=private, extracted=extracted)
        input_state["consumerInstalled"] = True
        precursor["freshBuild"] = {
            "main": sealed["identity"]["main"],
            "worker": sealed["identity"]["worker"],
            "buildManifest": sealed["identity"]["buildManifest"],
            "buildManifestRunId": sealed["identity"]["buildManifestValue"].get("runId"),
            "path": "target/ci-build/build-manifest.json",
        }
        precursor["identityComparison"] = sealed["comparison"]
        payloads.extend([
            ("fresh-build/build-manifest.json", sealed["manifest"]),
            ("fresh-build/identity.json", sealed["identityPath"]),
        ])

        # Absolute paths here: the worker is executed from fixture directories, so a
        # repository-relative spelling would resolve against the wrong cwd.
        consumer_options = [
            "--identity", str(subject / "target/ci-build/build-manifest.json"),
            "--main-binary", str(subject / "target/release/bin/main"),
            "--worker-binary", str(subject / "target/release/bin/chir-worker-main"),
        ]
        for stage_id in PRECURSOR_CONSUMERS:
            options = list(consumer_options)
            if stage_id == "cli":
                options.extend(["--output-root", str(private / "stages/cli-output")])
            result = replay.check_stage(stage_id, options)
            if result.exit_code != 0:
                capture["stageFailure"] = {
                    "stage": stage_id,
                    "exitCode": result.exit_code,
                    "invocation": {"identified": False,
                                   "reason": "the stage log is the evidence"},
                }
                raise Incomplete(f"the original {stage_id} stage failed")

        # The complete gate deletes the build trees it created before the identity
        # checking cohorts run. Only paths this run created are removed.
        removed = remove_owned_outputs(subject, build_outputs(subject) - preexisting)
        precursor["outputSweep"] = {
            "removedCount": sum(1 for item in removed if item["action"] == "removed"),
            "entries": removed,
            "preexisting": sorted(preexisting),
        }
        swept = subject_identity(subject, "the subject checkout after the precursors")
        if swept["worktreeSha256"] != before_identity["worktreeSha256"]:
            raise Incomplete(
                "the subject worktree is not the frozen tree after the precursor "
                "workload; a leftover output was reported instead of deleted")

        smoke_evidence = private / "stages/smoke/real-repository.json"
        smoke_evidence.parent.mkdir(mode=0o700, parents=True)
        smoke = replay.smoke_stage(smoke_evidence)
        if smoke.exit_code != 0:
            capture["stageFailure"] = {
                "stage": "smoke", "exitCode": smoke.exit_code,
                "invocation": {"identified": False,
                               "reason": "the stage log is the evidence"},
            }
            raise Incomplete("the original real-repository smoke failed")

        # -- native performance cohort ---------------------------------------- #
        baseline = subject / "tests/perf/baseline.json"
        require_regular_file(baseline, "frozen performance baseline")
        try:
            baseline_value = json.loads(baseline.read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            raise Incomplete(
                "the frozen performance baseline is unreadable: "
                + sanitize_detail(str(error))) from error
        if not isinstance(baseline_value, dict):
            raise Incomplete("the performance baseline is not a JSON object")
        if baseline_value.get("state") != "frozen" or \
                baseline_value.get("purpose") != "hard-ceiling":
            raise Incomplete("the performance baseline is not the frozen hard ceiling")
        recipe["perfCycles"] = baseline_value.get("cycles")
        recipe["profiles"] = [
            profile.get("name") for profile in baseline_value.get("profiles", [])
            if isinstance(profile, dict)
        ]

        # The cohort exercises the recovered product at its original path, so a
        # kernel core maps the very executable the measured invocation ran.
        product_binary = subject / "target/release/bin/main"
        if sha256_file(product_binary) != CANDIDATE_MEMBERS[
                "target/release/bin/main"]["sha256"]:
            raise Incomplete(
                "the restored product binary differs from the recovered candidate")
        launcher = write_self_core_launcher(
            private=private, main_binary=product_binary, subject=subject)
        cohort["launcher"] = {
            "purpose": "raise RLIMIT_CORE for the self cohort only, then exec",
            "execOnly": True,
            "argvPreserved": True,
            "measuresNothing": True,
            "addsNoProcess": True,
            "sha256": sha256_file(launcher),
            "bytes": launcher.stat().st_size,
            "coreLimitAppliedTo": "the self project only",
            "productBinary": "target/release/bin/main",
            "note": ("perf_gate.py is handed this launcher, so the private performance "
                     "evidence names the launcher digest as its binary; the product "
                     "digest is recorded under candidate.main"),
        }
        payloads.append(("cohort/self-core-exec", launcher))

        spool_before = {entry.name for entry in spool.iterdir()}
        perf_evidence = private / "stages/perf/performance.json"
        perf_evidence.parent.mkdir(mode=0o700, parents=True)
        perf = replay.perf_stage(binary=launcher, baseline=baseline,
                                 evidence=perf_evidence)
        launches = read_native_launches(private)
        cohort["basicInvocations"] = sum(item["profile"] == "basic" for item in launches)
        cohort["selfInvocations"] = sum(item["profile"] == "self" for item in launches)
        if perf.exit_code == 0:
            if [item["profile"] for item in launches] != ["basic"] * 5 + ["self"] * 5:
                raise Incomplete("the original native invocation sequence did not complete")
            capture["outcome"] = "naturalExitNoFaultObserved"
            capture["complete"] = True
            capture["detail"] = (
                "the complete original sequence ran and the native performance "
                "cohort observed no fault; the original failure remains open")
            status = EXIT_COMPLETE_NORMAL
        else:
            invocation = failing_invocation(perf.log, subject)
            capture["stageFailure"] = {
                "stage": "perf",
                "exitCode": perf.exit_code,
                "invocation": invocation,
            }
            attributed = invocation.get("project") == "."
            bound = bind_product_core(
                spool=spool, before=spool_before, subject=subject,
                main_binary=product_binary, private=private,
                attributed=bool(attributed))
            capture["core"] = bound
            capture["signal"] = bound.get("signal")
            if bound.get("bound"):
                capture["faultObserved"] = True
                capture["complete"] = True
                capture["outcome"] = "faultCapturedWithKernelCore"
                capture["detail"] = (
                    "a native fault was captured with a complete kernel core bound "
                    "to the failed self invocation; this capture does not identify a "
                    "root cause or fix the failure")
                status = EXIT_COMPLETE_FAULT
            else:
                bound["reason"] = sanitize_detail(str(
                    bound.get("reason") or "unknown reason"))
                raise Incomplete(
                    "the performance stage failed and no complete kernel core could "
                    "be bound to the self invocation (attribution "
                    f"{'self' if attributed else 'unattributed'}); "
                    + str(bound["reason"])
                    + "; the stage failure is preserved as the outcome")
        record_post_state(manifest, input_state)
    except Deadline as error:
        capture["complete"] = False
        capture["outcome"] = ("deadlineReached"
                              if capture["outcome"] == "incomplete"
                              else f"{capture['outcome']}ButIncomplete")
        capture["detail"] = sanitize_detail(str(error))
        status = EXIT_DEADLINE
        record_post_state(manifest, input_state)
    except Incomplete as error:
        detail = sanitize_detail(str(error))
        capture["complete"] = False
        capture["outcome"] = ("incompletePrerequisite"
                              if capture["outcome"] == "incomplete"
                              else f"{capture['outcome']}ButIncomplete")
        existing = capture.get("detail")
        capture["detail"] = f"{existing}; {detail}" if existing else detail
        status = EXIT_INCOMPLETE
        record_post_state(manifest, input_state)
    except OSError as error:
        capture["complete"] = False
        capture["outcome"] = ("incompletePrerequisite"
                              if capture["outcome"] == "incomplete"
                              else f"{capture['outcome']}ButIncomplete")
        existing = capture.get("detail")
        detail = f"an operating-system error stopped the run: {sanitize_detail(str(error))}"
        capture["detail"] = f"{existing}; {detail}" if existing else detail
        status = EXIT_INCOMPLETE
        record_post_state(manifest, input_state)

    if capture["complete"] and not (manifest.get("postRun") or {}).get("inputsVerified"):
        capture["complete"] = False
        capture["outcome"] += "ButInputsUnverified"
        capture["detail"] = "the consumed candidate or source/SDK inputs could not be reverified"
        status = EXIT_INCOMPLETE

    manifest["status"] = status
    manifest["finishedAt"] = utc_now()
    if replay is not None:
        precursor["stages"] = [stage_summary(result)
                               for result in replay.results.values()]
        observations = private / "observations.json"
        private_json(observations, {"boundaries": replay.observations})
        payloads.append(("observations.json", observations))
        for stage_id, result in replay.results.items():
            if result.log.is_file():
                payloads.append((f"logs/{stage_id}.log", result.log))
            stage_record = private / "ci-evidence" / stage_id / "stages.json"
            if stage_record.is_file():
                payloads.append((f"ci-evidence/{stage_id}/stages.json", stage_record))
    for name in ("sts-invocations.jsonl", "precheck.log",
                 "precheck-build-parameters.log"):
        path = private / "logs" / name
        if path.is_file() and path.stat().st_size > 0:
            payloads.append((f"logs/{name}", path))
    launch_record = private / "launcher/invocations.tsv"
    if launch_record.is_file():
        launches = read_native_launches(private)
        cohort["basicInvocations"] = sum(item["profile"] == "basic" for item in launches)
        cohort["selfInvocations"] = sum(item["profile"] == "self" for item in launches)
        payloads.append(("cohort/invocations.tsv", launch_record))
    for name, relative in (
        ("core/core.bin", "core/core.bin"),
        ("core/product.gdb", "core/product.gdb"),
        ("core/product.json", "core/product.json"),
        ("core/product-dump.log", "core/product-dump.log"),
        ("probe/probe-dump.log", "core-probe/probe-dump.log"),
        ("probe/probe.json", "core-probe/probe.json"),
        ("probe/probe.log", "core-probe/probe.log"),
    ):
        path = private / relative
        if path.is_file() and path.stat().st_size > 0:
            payloads.append((name, path))
    # Whatever each stage actually produced, including partial evidence from a stage
    # that failed, is packaged: a failed run must still carry its evidence. Only a
    # stage's own top-level files are taken, because the archive is USTAR and a deep
    # artifact tree would not fit its name field.
    for stage_directory in sorted((private / "stages").glob("*")):
        if not stage_directory.is_dir() or stage_directory.is_symlink():
            continue
        for path in sorted(stage_directory.iterdir()):
            if path.is_file() and not path.is_symlink() and path.stat().st_size > 0:
                payloads.append((f"stages/{stage_directory.name}/{path.name}", path))
    if input_state is not None:
        recovered_manifest = Path(
            input_state["candidateRoot"]) / "target/ci-build/build-manifest.json"
        if recovered_manifest.is_file():
            payloads.append(("candidate/build-manifest.json", recovered_manifest))

    manifest["capture"] = capture
    if isinstance(capture.get("detail"), str):
        capture["detail"] = sanitize_detail(capture["detail"])

    private_manifest = json.loads(json.dumps(manifest))
    private_manifest["heldOut"] = (
        "raw stage logs, the fresh build receipt, the bound core, the offline dump "
        "and these boundary observations are private")
    private_manifest_path = private / "private-manifest.json"
    private_json(private_manifest_path, private_manifest)
    deduplicated: list[tuple[str, Path]] = []
    seen: set[str] = set()
    for name, path in [("private-manifest.json", private_manifest_path), *payloads]:
        if name in seen or not path.is_file() or path.stat().st_size == 0:
            continue
        seen.add(name)
        deduplicated.append((name, path))

    openssl = shutil.which("openssl", path="/usr/local/bin:/usr/bin:/bin")
    try:
        if not deduplicated:
            raise Incomplete("no evidence payload was collected")
        if openssl is None:
            raise Incomplete("openssl is not installed")
        archive_path = private / "evidence.tar.gz"
        deterministic_archive(deduplicated, archive_path)
        manifest["evidence"]["members"] = verify_archive(archive_path, deduplicated)
        manifest["evidence"]["archiveBytes"] = archive_path.stat().st_size
        manifest["evidence"]["archiveSha256"] = sha256_file(archive_path)
        ciphertext = output / "public/private-evidence.p7m"
        ciphertext.parent.mkdir(mode=0o700, exist_ok=True)
        encrypt_evidence(
            archive_path, openssl,
            Path(os.path.abspath(os.fspath(arguments.certificate))), ciphertext,
            minimal_environment("/usr/local/bin:/usr/bin:/bin"))
        manifest["evidence"]["ciphertextBytes"] = ciphertext.stat().st_size
        manifest["evidence"]["ciphertextSha256"] = sha256_file(ciphertext)
    except Incomplete as error:
        capture["complete"] = False
        existing = capture.get("detail")
        detail = "evidence packaging failed: " + sanitize_detail(str(error))
        capture["detail"] = f"{existing}; {detail}" if existing else detail
        manifest["evidence"]["ciphertextSha256"] = None
        manifest["evidence"]["ciphertextBytes"] = None
        status = EXIT_INCOMPLETE
        manifest["status"] = status

    manifest["capture"] = capture
    if isinstance(capture.get("detail"), str):
        capture["detail"] = sanitize_detail(capture["detail"])
    manifest["collectorExitCode"] = (
        0 if capture["complete"]
        and manifest["status"] in (EXIT_COMPLETE_NORMAL, EXIT_COMPLETE_FAULT)
        else int(manifest["status"]))
    write_public(output, manifest, diagnosis_text(manifest))
    leaked = sorted(
        entry.name for entry in (output / "public").iterdir()
        if entry.name not in PUBLIC_FILES)
    if leaked:
        raise SystemExit(
            "the public directory contains a non-allowlisted entry: " + leaked[0])
    print(json.dumps({
        "schemaVersion": SCHEMA,
        "status": manifest["status"],
        "outcome": capture["outcome"],
        "complete": capture["complete"],
        "faultObserved": capture["faultObserved"],
        "evidence": manifest["evidence"]["ciphertextSha256"],
        "public": sorted(entry.name for entry in (output / "public").iterdir()),
    }, sort_keys=True))
    return int(manifest["collectorExitCode"])


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
