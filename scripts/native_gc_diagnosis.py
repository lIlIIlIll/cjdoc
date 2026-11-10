#!/usr/bin/env python3
"""Single-shot native GC diagnostic capture for one frozen Linux candidate.

This tool is diagnostic evidence collection, not an acceptance gate, not a
release retry and not a fix. It binds one recovered candidate binary, the exact
source tree and toolchain that produced it, runs that binary exactly once under
a real debugger at the original default GC timing with a 512MB heap, captures
the fault (or the natural completion) plus a private core, and publishes only a
small normalized summary and a CMS-encrypted evidence bundle.

Published (``<output>/public``)::

    manifest.json
    diagnosis.txt
    private-evidence.p7m

Nothing else leaves the machine in the public directory. Raw debugger output,
GC reports and cores stay in ``<output>/private`` and inside the ciphertext.

Collector exit status:

    0    collection complete (normal output or a captured fault with a core)
    124  diagnostic deadline reached; capture grace applied, then stopped
    255  the debugger failed or produced no trustworthy capture
    2    another incomplete run (prerequisite, invocation or post-run drift)

Manifest status 0 means normal output; 11 means a captured native fault.
Collector success never changes the native outcome or qualifies a release.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import threading
import time

sys.dont_write_bytecode = True

try:
    from .worktree_identity import exact_worktree_identity
except ImportError:  # Direct script execution.
    from worktree_identity import exact_worktree_identity


SCHEMA = "cjdoc.native-gc-diagnosis/1"

# Frozen candidate identity (the recovered failed 0.7.8 Linux build).
SUBJECT_COMMIT = "d0fb6d3e4646bfda005502d845a1f551f239bf9e"
SUBJECT_TREE = "644953a988995309dc9006d15308a7ef51ee29e8"
CANDIDATE_REPOSITORY = "lIlIIlIll/cjdoc"
CANDIDATE_RUN_ID = 42704455770
CANDIDATE_ATTEMPT = 1
CANDIDATE_ARTIFACT_ID = 13712324192
CANDIDATE_TAR_NAME = "cjdoc-linux-candidate.tar"
CANDIDATE_TAR_BYTES = 27637760
CANDIDATE_TAR_SHA256 = (
    "05a424f712603feff3b76a2f7d43d0fa1a88a42c65259062971a92ea455e38da"
)
CANDIDATE_MEMBERS = {
    "target/release/bin/main": {
        "bytes": 20002104,
        "sha256": "e197a23bbcd8313f8566abeabeb97dc3d96c2ad9d9890b6a0fb119e67e077937",
    },
    "target/release/bin/chir-worker-main": {
        "bytes": 7621176,
        "sha256": "fecbb301d34981411be3153638f87c49c5c9c11daaa123ef27403049adf0f7d7",
    },
    "target/ci-build/build-manifest.json": {"bytes": 1140, "sha256": None},
}
CANDIDATE_VERSION_OUTPUT = "cjdoc 0.7.8"

# Frozen toolchain identity.
SDK_VERSION = "1.2.0 (cjnative)"
SDK_TARGET = "x86_64-unknown-linux-gnu"
SDK_FINGERPRINT = (
    "282c2bc7d0ba20d500d6930649c5a672c173c0b0ce1f76c8f4d8d0a7866aec0a"
)
STDX_DIGEST = (
    "e62289d5b88af440de04a26a30c79403d024f6accfacfd96607ae409ad9c1df2"
)
CJC_SHA256 = "023be1bb2ded1078906fc91919b3c1175ad14436ad88d23d505f7b8dcd0d7118"
LLC_SHA256 = "f7031856b26d579614201cbee94bb3c609cefc01f7cd1e8b96aaaf205e7ba3d5"
STDX_ARTIFACT_SUFFIXES = {".a", ".bc", ".cjo", ".dll", ".dylib", ".so"}
STDX_REQUIRED_ARTIFACTS = ("stdx.chir.cjo", "libstdx.chir.a")
NATIVE_LIBRARIES = (
    ("libboundscheck.so", 71720,
     "3ad04fe38be88d5123078bd11d78cbc82377c114f6e6514b393ecd374e559bb7"),
    ("libcangjie-runtime.so", 4392824,
     "2e32485852cbc8648c1298c23f2d1ff5f90bdb6c0331da20b29ee3d97d03e167"),
    ("libcangjie-std-ast.so", 10110872,
     "1675d166abb355eaa8f045f32536b0b387dc9e68a36413a8fc9f32aa3159e46b"),
    ("libcangjie-std-collection.so", 858640,
     "4c01ea53b77b325d39b4db1a6180db854baa7fa1c2b678ec07d9beb721d6ab4e"),
    ("libcangjie-std-core.so", 941728,
     "93e6d365ca9f03b19a4e42b5a4fd6258f18e829c3d2acd5b7eb3141ecb96b529"),
    ("libcangjie-std-math.so", 314096,
     "00775adf52e28ff350345692b2aafbd446acd9a2f52b84e5adcad6ce16eba30c"),
    ("libcangjie-std-sort.so", 180368,
     "274d82e56e7ee50fbcd602ccd1136bff889b4e2bca34d531eb26cf6c937dd3da"),
)

# Frozen public encryption recipient (never a private key).
CERTIFICATE_SHA256 = (
    "7f97b417287e770f3c880a9b24b8709fd0942af8536fd1d067153fd93d7f42f2"
)

# Original runtime recipe: nothing here is overridable from the command line.
HEAP = "512MB"
JOBS = 1
DIAGNOSTIC_DEADLINE_SECONDS = 900
GDB_GRACE_SECONDS = 90
MAX_REPORT_BYTES = 32 * 1024 * 1024
NORMAL_DOCS_SHA256 = (
    "2f62b7b1d8efed812891591fecd0a72d6257140b3529d6a7108067f03015ef4f"
)
NORMAL_DECLARATION_COUNT = 5939

EXIT_COMPLETE_NORMAL = 0
EXIT_COMPLETE_FAULT = 11
EXIT_DEADLINE = 124
EXIT_GDB_FAILURE = 255
EXIT_INCOMPLETE = 2

PUBLIC_FILES = ("manifest.json", "diagnosis.txt", "private-evidence.p7m")

COMMIT = re.compile(r"^[0-9a-f]{40}$")
DIGITS = re.compile(r"^[0-9]+$")
GDB_PRINT_COMMANDS = (
    "info program",
    "p $_siginfo",
    "info registers",
    "info threads",
    "thread apply all bt 80",
    "info sharedlibrary",
    "info proc mappings",
    "x/32i $pc-32",
    "x/32gx $rdi-32",
    "x/64bx $rdi",
)


class Incomplete(RuntimeError):
    """A prerequisite, invocation or identity check did not hold."""


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def file_identity(path: Path) -> dict[str, object]:
    return {"bytes": path.stat().st_size, "sha256": sha256_file(path)}


def require_regular_file(path: Path, description: str) -> Path:
    try:
        metadata = path.lstat()
    except FileNotFoundError as error:
        raise Incomplete(f"{description} is missing") from error
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise Incomplete(f"{description} must be a regular non-symlink file")
    return path


def require_directory(path: Path, description: str) -> Path:
    try:
        metadata = path.lstat()
    except FileNotFoundError as error:
        raise Incomplete(f"{description} is missing") from error
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        raise Incomplete(f"{description} must be a regular non-symlink directory")
    return path


def run_checked(command: list[str], *, env: dict[str, str],
                 timeout: int) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            command, check=False, capture_output=True, text=True, timeout=timeout,
            env=env, stdin=subprocess.DEVNULL,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise Incomplete(
            f"cannot execute {Path(command[0]).name}: {error}") from error


ABSOLUTE_TOKEN = re.compile(r"/[^\s,;()'\"]+")


def sanitize_detail(text: str) -> str:
    """Strip machine paths from anything that can reach a published summary."""
    return ABSOLUTE_TOKEN.sub("<path>", text)


def target_family(target: str) -> str:
    normalized = target.strip().lower()
    architecture = normalized.split("-", 1)[0]
    architecture = {"amd64": "x86_64", "arm64": "aarch64"}.get(
        architecture, architecture)
    if architecture not in {"x86_64", "aarch64"}:
        raise Incomplete("unsupported compiler target architecture")
    if "linux" in normalized:
        platform = "linux"
    elif "windows" in normalized or "mingw" in normalized:
        platform = "windows"
    elif "darwin" in normalized or "apple" in normalized:
        platform = "darwin"
    else:
        raise Incomplete("unsupported compiler target platform")
    return f"{platform}_{architecture}"


def minimal_environment(path: str) -> dict[str, str]:
    """The only environment a native/GDB child may inherit.

    Built from scratch on purpose: no authentication variable and no wildcard
    ``CJDOC_*``/``cj*`` value from the caller reaches the child. The runtime
    recipe is fixed here rather than supplied by the caller.
    """
    return {
        "PATH": path,
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
        "TZ": "UTC",
        "PYTHONDONTWRITEBYTECODE": "1",
        "PYTHONUTF8": "1",
        "PYTHONHASHSEED": "0",
    }


def candidate_extraction_destination(root: Path, member: str) -> Path:
    relative = Path(member)
    if relative.is_absolute() or ".." in relative.parts:
        raise Incomplete("candidate archive member escapes its destination")
    return root / relative


def extract_candidate(archive_path: Path, destination: Path,
                      identities: dict[str, dict[str, object]]) -> None:
    """Extract exactly the three expected members into fixed destinations."""
    expected = set(CANDIDATE_MEMBERS)
    try:
        with tarfile.open(archive_path, "r:") as archive:
            members = archive.getmembers()
            files = [member for member in members if member.isfile()]
            if len(files) != len(members):
                raise Incomplete("candidate archive contains a non-regular member")
            names = [member.name for member in files]
            if sorted(names) != sorted(expected) or len(set(names)) != len(names):
                raise Incomplete("candidate archive member set is not the frozen set")
            for member in files:
                wanted = CANDIDATE_MEMBERS[member.name]
                if member.size != wanted["bytes"]:
                    raise Incomplete(
                        f"candidate member {member.name} has an unexpected size")
                target = candidate_extraction_destination(destination, member.name)
                target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                stream = archive.extractfile(member)
                if stream is None:
                    raise Incomplete(f"candidate member {member.name} is unreadable")
                digest = hashlib.sha256()
                written = 0
                descriptor = os.open(
                    target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o700)
                try:
                    while True:
                        block = stream.read(1024 * 1024)
                        if not block:
                            break
                        written += len(block)
                        if written > wanted["bytes"]:
                            raise Incomplete(
                                f"candidate member {member.name} exceeds its frozen size")
                        digest.update(block)
                        view = memoryview(block)
                        while view:
                            written_now = os.write(descriptor, view)
                            view = view[written_now:]
                finally:
                    os.close(descriptor)
                if written != wanted["bytes"]:
                    raise Incomplete(
                        f"candidate member {member.name} is truncated")
                observed = digest.hexdigest()
                pinned = wanted["sha256"]
                if pinned is not None and observed != pinned:
                    raise Incomplete(
                        f"candidate member {member.name} differs from the frozen bytes")
                identities[member.name] = {"bytes": written, "sha256": observed}
    except (tarfile.TarError, OSError) as error:
        raise Incomplete(f"candidate archive is unreadable: {error}") from error


def verify_build_manifest(path: Path) -> dict[str, object]:
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise Incomplete(f"build manifest is unreadable: {error}") from error
    if not isinstance(manifest, dict):
        raise Incomplete("build manifest is not a JSON object")
    checks = (
        (("schemaVersion",), "cjdoc.ci-build-manifest/1"),
        (("checkoutCommit",), SUBJECT_COMMIT),
        (("checkoutTree",), SUBJECT_TREE),
        (("mainBinary", "sha256"), CANDIDATE_MEMBERS[
            "target/release/bin/main"]["sha256"]),
        (("workerBinary", "sha256"), CANDIDATE_MEMBERS[
            "target/release/bin/chir-worker-main"]["sha256"]),
        (("mainBinary", "size"), CANDIDATE_MEMBERS[
            "target/release/bin/main"]["bytes"]),
        (("toolchain", "version"), SDK_VERSION),
        (("toolchain", "target"), SDK_TARGET),
        (("toolchain", "fingerprint"), SDK_FINGERPRINT),
        (("toolchain", "stdxDigest"), STDX_DIGEST),
        (("runId",), str(CANDIDATE_RUN_ID)),
        (("runAttempt",), CANDIDATE_ATTEMPT),
    )
    for keys, wanted in checks:
        value: object = manifest
        for key in keys:
            if not isinstance(value, dict) or key not in value:
                raise Incomplete(
                    f"build manifest is missing {'.'.join(keys)}")
            value = value[key]
        if value != wanted:
            raise Incomplete(
                f"build manifest {'.'.join(keys)} does not match the frozen identity")
    compile_options = manifest.get("compileOptions")
    if not isinstance(compile_options, list) or not all(
            isinstance(item, str) for item in compile_options):
        raise Incomplete("build manifest compileOptions is malformed")
    return {
        "checkoutCommit": manifest["checkoutCommit"],
        "checkoutTree": manifest["checkoutTree"],
        "compileOptions": list(compile_options),
        "effectiveManifest": manifest.get("effectiveManifest"),
        "mainBinarySha256": manifest["mainBinary"]["sha256"],
        "workerBinarySha256": manifest["workerBinary"]["sha256"],
    }


def stdx_tree_digest(stdx_root: Path) -> str:
    """Digest a static stdx sidecar exactly the way the build wrapper does."""
    require_directory(stdx_root, "static stdx sidecar")
    if stdx_root.name != "stdx":
        raise Incomplete("the static stdx sidecar has an unexpected layout")
    for name in STDX_REQUIRED_ARTIFACTS:
        require_regular_file(stdx_root / name, f"stdx artifact {name}")
    digest = hashlib.sha256()
    for item in sorted(stdx_root.iterdir(), key=lambda entry: entry.name):
        if item.is_symlink():
            raise Incomplete("the static stdx sidecar contains a symlink")
        if not item.is_file():
            continue
        if not (item.suffix in STDX_ARTIFACT_SUFFIXES or item.name.startswith("lib")):
            continue
        digest.update(item.name.encode("utf-8"))
        digest.update(b"\0")
        with item.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
        digest.update(b"\0")
    return digest.hexdigest()


def verify_sdk(sdk_root: Path, stdx_root: Path,
               compiler_env: dict[str, str]) -> dict[str, object]:
    """Bind the SDK: compiler, llc, static stdx and the seven native libraries.

    Hashing files under the SDK root is not enough. The recovered main binary
    must actually resolve every Cangjie DSO to these pinned files through the
    same allowlisted ``LD_LIBRARY_PATH`` the capture uses; only then are the
    resolved bytes hashed.
    """
    require_directory(sdk_root, "SDK root")
    cjc = sdk_root / "bin" / "cjc"
    require_regular_file(cjc, "SDK compiler")
    canonical_llc = sdk_root / "third_party" / "llvm" / "bin" / "llc"
    llc: Path | None = canonical_llc if canonical_llc.is_file() and \
        not canonical_llc.is_symlink() else None
    if llc is None or sha256_file(llc) != LLC_SHA256:
        # The installer may relocate the bundled LLVM subtree; accept only a
        # candidate whose bytes are the pinned optimizer.
        llc = next(
            (candidate for candidate in sorted(sdk_root.rglob("llc"))
             if candidate.is_file() and not candidate.is_symlink()
             and sha256_file(candidate) == LLC_SHA256),
            None,
        )
    if llc is None:
        raise Incomplete("the pinned SDK optimizer is missing or differs")
    cjc_identity = file_identity(cjc)
    if cjc_identity["sha256"] != CJC_SHA256:
        raise Incomplete("SDK compiler bytes differ from the pinned compiler")

    completed = run_checked([str(cjc), "-v"], env=compiler_env, timeout=60)
    output = f"{completed.stdout}\n{completed.stderr}"
    if completed.returncode != 0:
        raise Incomplete("SDK compiler did not report its version")
    version = re.search(r"Cangjie Compiler:\s*([^\n]+)", output)
    target = re.search(r"Target:\s*([^\n]+)", output)
    if version is None or target is None:
        raise Incomplete("SDK compiler version output is incomplete")
    if version.group(1).strip() != SDK_VERSION:
        raise Incomplete("SDK compiler version differs from the pinned version")
    if target.group(1).strip() != SDK_TARGET:
        raise Incomplete("SDK compiler target differs from the pinned target")

    family = target_family(target.group(1))
    native_directory = sdk_root / "runtime" / "lib" / f"{family}_cjnative"
    require_directory(native_directory, "SDK native library directory")
    for name, expected_bytes, expected_sha in NATIVE_LIBRARIES:
        path = require_regular_file(
            native_directory / name, f"SDK native library {name}")
        if path.lstat().st_size != expected_bytes:
            raise Incomplete(f"SDK native library {name} has an unexpected size")
        if sha256_file(path) != expected_sha:
            raise Incomplete(f"SDK native library {name} differs from the pin")

    require_directory(stdx_root, "static stdx sidecar")
    stdx_digest = stdx_tree_digest(stdx_root)
    if stdx_digest != STDX_DIGEST:
        raise Incomplete("the static stdx sidecar digest differs from the pin")
    fingerprint = hashlib.sha256(
        f"{version.group(1).strip()}\0{target.group(1).strip()}\0"
        f"{stdx_digest}\0".encode("utf-8")
    ).hexdigest()
    if fingerprint != SDK_FINGERPRINT:
        raise Incomplete("the toolchain fingerprint differs from the pin")
    return {
        "sdkVersion": SDK_VERSION,
        "target": SDK_TARGET,
        "family": family,
        "nativeDirectory": native_directory,
        "toolsDirectory": sdk_root / "tools" / "lib",
        "stdxDigest": stdx_digest,
        "fingerprint": fingerprint,
        "cjcSha256": cjc_identity["sha256"],
        "llcSha256": file_identity(llc)["sha256"],
    }


def verify_ldd(binary: Path, sdk: dict[str, object],
               environment: dict[str, str]) -> dict[str, str]:
    completed = run_checked(
        ["ldd", str(binary)], env=environment, timeout=120)
    if completed.returncode != 0:
        raise Incomplete("ldd could not resolve the recovered binary")
    resolutions: dict[str, str] = {}
    for line in completed.stdout.splitlines():
        stripped = line.strip()
        if "=>" not in stripped:
            continue
        name, _, rest = stripped.partition("=>")
        name = name.strip()
        destination = rest.strip().split(" (", 1)[0].strip()
        if not destination or destination == "not found":
            continue
        try:
            resolutions[name] = str(Path(destination).resolve(strict=True))
        except OSError as error:
            raise Incomplete(f"ldd reported an unreadable library {name}") from error
    native_directory = sdk["nativeDirectory"]
    assert isinstance(native_directory, Path)
    try:
        native_resolved = native_directory.resolve(strict=True)
    except OSError as error:
        raise Incomplete("the pinned SDK native directory is not resolvable") from error
    for name, _bytes, expected_sha in NATIVE_LIBRARIES:
        observed = resolutions.get(name)
        if observed is None:
            raise Incomplete(f"the recovered binary does not need {name}")
        expected = native_resolved / name
        if Path(observed) != expected:
            raise Incomplete(
                f"{name} resolves outside the pinned SDK native directory")
        if sha256_file(Path(observed)) != expected_sha:
            raise Incomplete(f"the resolved bytes of {name} differ from the pin")
    # A duplicate Cangjie runtime elsewhere on the search path would silently
    # take over, so every resolved runtime library must be the pinned one.
    for name, destination in resolutions.items():
        if not (name.startswith("libcangjie-") or name == "libboundscheck.so"):
            continue
        if Path(destination).parent != native_resolved:
            raise Incomplete(
                f"{name} resolves to a non-pinned runtime directory")
    return {name: resolutions[name] for name, _b, _s in NATIVE_LIBRARIES}


def gdb_script_text(capture_path: Path, core_path: Path) -> str:
    commands = "\n".join(f"        {command!r}," for command in GDB_PRINT_COMMANDS)
    return f"""set pagination off
set confirm off
set disable-randomization off
set startup-with-shell off
set print thread-events off
set follow-fork-mode parent
set detach-on-fork on
handle SIGPIPE nostop noprint pass
handle SIGUSR1 nostop noprint pass
handle SIGUSR2 nostop noprint pass
handle SIG34 nostop noprint pass
handle SIG35 nostop noprint pass
handle SIG36 nostop noprint pass
handle SIG37 nostop noprint pass
handle SIG38 nostop noprint pass
handle SIG39 nostop noprint pass
handle SIG40 nostop noprint pass
handle SIG41 nostop noprint pass
python
import gdb
import json

CAPTURE_PATH = {str(capture_path)!r}
CORE_PATH = {str(core_path)!r}
COMMANDS = [
{commands}
]
state = {{
    "stopSignal": None,
    "exitCode": None,
    "runError": None,
    "inferiorPid": 0,
    "coreAttempted": False,
    "coreError": None,
}}


def _thread_map(event):
    thread = event.inferior_thread
    print("DIAGNOSTIC_THREAD_MAP " + json.dumps({{
        "inferiorPid": thread.inferior.pid,
        "ptid": [int(part) for part in thread.ptid],
        "globalThread": int(thread.global_num),
    }}), flush=True)


def _stopped(event):
    state["stopSignal"] = str(getattr(event, "stop_signal", "") or "")


gdb.events.new_thread.connect(_thread_map)
gdb.events.stop.connect(_stopped)
try:
    gdb.execute("run")
except gdb.error as error:
    state["runError"] = str(error)
try:
    state["exitCode"] = int(gdb.parse_and_eval("$_exitcode"))
except Exception:
    state["exitCode"] = None
inferior = gdb.selected_inferior()
state["inferiorPid"] = int(inferior.pid or 0)
print("DIAGNOSTIC_CAPTURE " + json.dumps(state, sort_keys=True), flush=True)
if state["inferiorPid"]:
    for command in COMMANDS:
        print("DIAGNOSTIC_COMMAND " + command, flush=True)
        try:
            print(gdb.execute(command, to_string=True), flush=True)
        except gdb.error as error:
            print("DIAGNOSTIC_READ_ERROR " + str(error), flush=True)
    state["coreAttempted"] = True
    try:
        gdb.execute("generate-core-file " + CORE_PATH)
        print("DIAGNOSTIC_CORE_OK", flush=True)
    except gdb.error as error:
        state["coreError"] = str(error)
        print("DIAGNOSTIC_CORE_ERROR " + str(error), flush=True)
else:
    print("DIAGNOSTIC_NOTHING_TO_CAPTURE: the inferior is not running", flush=True)
with open(CAPTURE_PATH, "x", encoding="utf-8") as stream:
    json.dump(state, stream, indent=2, sort_keys=True)
    stream.write("\\n")
end
quit
"""


class ReportDrainer:
    """Drain the runtime GC report FIFO without ever blocking the child.

    The SDK truncates a per-process report file, so the report is routed to a
    FIFO owned here. Retention stops at the preregistered bound, but draining
    continues and the truncation is recorded instead of stalling the runtime.
    """

    def __init__(self, fifo: Path, report: Path, limit: int) -> None:
        self.fifo = fifo
        self.report = report
        self.limit = limit
        self.received = 0
        self.retained = 0
        self.errors: list[str] = []
        self.stop = threading.Event()
        self.reader: threading.Thread | None = None
        self.selector = selectors.DefaultSelector()
        self.descriptor = -1

    def start(self) -> None:
        os.mkfifo(self.fifo, mode=0o600)
        self.descriptor = os.open(
            self.fifo, os.O_RDWR | os.O_NONBLOCK | os.O_CLOEXEC)
        self.selector.register(self.descriptor, selectors.EVENT_READ)
        self.reader = threading.Thread(target=self._drain, daemon=True)
        self.reader.start()

    def _drain(self) -> None:
        try:
            with self.report.open("xb") as output:
                os.chmod(self.report, 0o600)
                while True:
                    ready = self.selector.select(0.1)
                    if not ready and self.stop.is_set():
                        break
                    for _key, _events in ready:
                        try:
                            chunk = os.read(self.descriptor, 65536)
                        except BlockingIOError:
                            continue
                        if not chunk and self.stop.is_set():
                            return
                        self.received += len(chunk)
                        remaining = self.limit - self.retained
                        if remaining > 0:
                            kept = chunk[:remaining]
                            output.write(kept)
                            output.flush()
                            self.retained += len(kept)
        except BaseException as error:  # keep the reason for the receipt
            self.errors.append(repr(error))

    def finish(self) -> dict[str, object]:
        self.stop.set()
        if self.reader is not None:
            self.reader.join(timeout=20)
        self.selector.close()
        if self.descriptor >= 0:
            os.close(self.descriptor)
        if self.reader is not None and self.reader.is_alive():
            raise Incomplete("the GC report drainer did not stop")
        if self.errors:
            raise Incomplete("the GC report drainer failed: " + self.errors[0])
        try:
            digest = sha256_file(self.report)
        except OSError as error:
            raise Incomplete(
                f"the GC report was not written: {error}") from error
        return {
            "receivedBytes": self.received,
            "retainedBytes": self.retained,
            "truncated": self.received > self.retained,
            "sha256": digest,
        }


def minimum_allowed_cpu() -> int:
    try:
        allowed = os.sched_getaffinity(0)
    except (AttributeError, OSError):
        allowed = set()
    if not allowed:
        raise Incomplete("the process CPU affinity is unavailable")
    return min(allowed)


def write_private_json(path: Path, payload: object) -> None:
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n",
                    encoding="utf-8")


def deterministic_archive(payloads: list[tuple[str, Path]], destination: Path) -> None:
    """Stream actual evidence with anonymous archive and compression metadata."""
    with destination.open("xb") as output:
        os.chmod(destination, 0o600)
        with gzip.GzipFile(filename="", mode="wb", fileobj=output, mtime=0,
                           compresslevel=6) as compressed:
            with tarfile.open(fileobj=compressed, mode="w|",
                              format=tarfile.USTAR_FORMAT) as archive:
                for name, path in payloads:
                    metadata = path.lstat()
                    if not stat.S_ISREG(metadata.st_mode):
                        raise Incomplete(f"evidence payload {name} is not a regular file")
                    info = tarfile.TarInfo(name)
                    info.size = metadata.st_size
                    info.mode = 0o600
                    info.uid = info.gid = 0
                    info.uname = info.gname = ""
                    info.mtime = 0
                    info.type = tarfile.REGTYPE
                    with path.open("rb") as stream:
                        archive.addfile(info, stream)


def verify_archive(archive: Path, payloads: list[tuple[str, Path]]
                   ) -> list[dict[str, object]]:
    """Reopen the produced archive and confirm the complete payload inventory.

    Only then may the inventory be published: the claim is that the ciphertext
    holds exactly these payloads with these bytes and no owner or path
    metadata, so it is checked from the archived bytes, not from the source
    files.
    """
    expected = {
        name: (path.stat().st_size, sha256_file(path)) for name, path in payloads
    }
    observed: list[dict[str, object]] = []
    with tarfile.open(archive, mode="r:gz") as reopened:
        members = reopened.getmembers()
        names = [member.name for member in members]
        if sorted(names) != sorted(expected) or len(set(names)) != len(names):
            raise Incomplete("the evidence archive inventory is not the payload set")
        for member in members:
            if not member.isfile():
                raise Incomplete("the evidence archive holds a non-regular member")
            if member.uid != 0 or member.gid != 0 \
                    or member.uname or member.gname:
                raise Incomplete("the evidence archive carries owner metadata")
            if member.mtime != 0:
                raise Incomplete("the evidence archive carries a timestamp")
            if member.size != expected[member.name][0]:
                raise Incomplete("an evidence member size changed while archiving")
            stream = reopened.extractfile(member)
            if stream is None:
                raise Incomplete("an evidence member is unreadable in the archive")
            digest = hashlib.sha256()
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
            if digest.hexdigest() != expected[member.name][1]:
                raise Incomplete("an evidence member changed while archiving")
            observed.append({
                "name": member.name,
                "bytes": member.size,
                "sha256": digest.hexdigest(),
            })
    return observed


def check_inputs_unchanged(inputs: dict[str, object]) -> None:
    """Re-verify that the capture left its exact inputs byte-identical."""
    subject = inputs["subject"]
    before = inputs["before"]
    extracted = inputs["extracted"]
    candidate_root = inputs["candidateRoot"]
    native_directory = inputs["nativeDirectory"]
    assert isinstance(subject, Path) and isinstance(before, dict)
    assert isinstance(extracted, dict)
    assert isinstance(candidate_root, Path) and isinstance(native_directory, Path)
    after = exact_worktree_identity(subject, expected_commit=SUBJECT_COMMIT)
    for key in ("headCommit", "tree", "worktreeSha256"):
        if after[key] != before[key]:
            raise Incomplete("the subject worktree changed during the capture")
    for member, expected in extracted.items():
        assert isinstance(expected, dict)
        if sha256_file(candidate_root / member) != expected["sha256"]:
            raise Incomplete(
                "an extracted candidate binary changed during the capture")
    for name, _bytes, expected_sha in NATIVE_LIBRARIES:
        if sha256_file(native_directory / name) != expected_sha:
            raise Incomplete(
                "a pinned SDK native library changed during the capture")


def record_input_state(manifest: dict[str, object],
                       inputs: dict[str, object] | None) -> None:
    """State whether the capture's own inputs survived, without ever assuming."""
    if inputs is None:
        manifest["sourceUnchanged"] = None
        manifest["binaryUnchanged"] = None
        manifest["sdkUnchanged"] = None
        return
    try:
        check_inputs_unchanged(inputs)
    except (Incomplete, OSError) as error:
        manifest["sourceUnchanged"] = False
        manifest["binaryUnchanged"] = False
        manifest["sdkUnchanged"] = False
        manifest["inputDrift"] = sanitize_detail(str(error))
        return
    manifest["sourceUnchanged"] = True
    manifest["binaryUnchanged"] = True
    manifest["sdkUnchanged"] = True


def collect_evidence_payloads(private: Path,
                              payloads: list[tuple[str, Path]]) -> None:
    """Append whichever real evidence files this run actually produced.

    Evidence is gathered from what exists on disk rather than from the intended
    plan, so a run that stops early still packages everything it reached.
    """
    candidates = (
        ("gdb.log", private / "gdb" / "gdb.log"),
        ("capture.gdb", private / "gdb" / "capture.gdb"),
        ("gc-report.log", private / "report" / "gc-report.log"),
        ("capture.json", private / "capture.json"),
        ("core.bin", private / "core.bin"),
    )
    present = {name for name, _path in payloads}
    for name, path in candidates:
        if name in present:
            continue
        if path.is_file() and not path.is_symlink() and path.stat().st_size > 0:
            payloads.append((name, path))
            present.add(name)




def encrypt_evidence(archive: Path, openssl: str, certificate: Path,
                     ciphertext: Path, environment: dict[str, str]) -> None:
    require_regular_file(certificate, "public encryption certificate")
    if sha256_file(certificate) != CERTIFICATE_SHA256:
        raise Incomplete("the encryption certificate differs from the pin")
    descriptor = os.open(
        ciphertext, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    os.close(descriptor)
    completed = run_checked(
        [openssl, "cms", "-encrypt", "-binary", "-aes256",
         "-outform", "DER", "-in", str(archive), "-out", str(ciphertext),
         str(certificate)],
        env=environment, timeout=300,
    )
    if completed.returncode != 0 or ciphertext.stat().st_size == 0:
        raise Incomplete("CMS encryption did not produce a ciphertext")


def verify_report_recipe(report: Path) -> dict[str, object]:
    """Read the runtime's own statement of the recipe it started with.

    A field the runtime printed with a different value means the capture did not
    run the frozen recipe and is a hard failure. A field the runtime never
    printed (for example because it faulted before the banner) is recorded as
    absent instead of discarding otherwise valid fault evidence.
    """
    text = report.read_text(encoding="utf-8", errors="replace")
    fields: dict[str, str] = {}
    for line in text.splitlines():
        stripped = line.strip()
        if ":" not in stripped:
            continue
        key, _, value = stripped.partition(":")
        if key in ("Heap size", "GC Threshold", "GC interval",
                   "Backup GC interval", "Processor number"):
            fields[key] = value.strip()
    expected = {
        "Heap size": "524288(KB)",
        "GC Threshold": "524288(KB)",
        "GC interval": "150ms",
        "Backup GC interval": "240s",
    }
    for key, wanted in expected.items():
        if key in fields and fields[key] != wanted:
            raise Incomplete(
                f"the captured runtime report shows an overridden {key.lower()}")
    processors = fields.get("Processor number", "")
    return {
        "bannerPresent": bool(fields),
        "heap": fields.get("Heap size"),
        "gcThreshold": fields.get("GC Threshold"),
        "gcInterval": fields.get("GC interval"),
        "backupGcInterval": fields.get("Backup GC interval"),
        # The count follows the narrowed CPU affinity rather than the GC
        # recipe, so it is recorded, not asserted.
        "processorNumber": int(processors) if processors.isdigit() else None,
    }


def summarize_gdb_log(path: Path) -> dict[str, object]:
    text = path.read_text(encoding="utf-8", errors="replace")
    thread_records = 0
    inferiors: set[int] = set()
    marker = "DIAGNOSTIC_THREAD_MAP "
    for line in text.splitlines():
        if not line.startswith(marker):
            continue
        try:
            record = json.loads(line[len(marker):])
        except ValueError:
            continue
        thread_records += 1
        inferior = record.get("inferiorPid")
        if isinstance(inferior, int):
            inferiors.add(inferior)
    return {
        "threadMapRecords": thread_records,
        "inferiorCount": len(inferiors),
        "hasFaultStop": "Program received signal" in text,
        "coreSaved": "DIAGNOSTIC_CORE_OK" in text,
        "sections": {
            command: f"DIAGNOSTIC_COMMAND {command}" in text
            for command in GDB_PRINT_COMMANDS
        },
    }


def write_public(output: Path, manifest: dict[str, object],
                 diagnosis: str) -> None:
    public = output / "public"
    public.mkdir(mode=0o700, exist_ok=True)
    (public / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(public / "manifest.json", 0o644)
    (public / "diagnosis.txt").write_text(diagnosis, encoding="utf-8")
    os.chmod(public / "diagnosis.txt", 0o644)


def diagnosis_text(manifest: dict[str, object]) -> str:
    capture = manifest["capture"]
    candidate = manifest["candidate"]
    assert isinstance(capture, dict) and isinstance(candidate, dict)
    toolchain = manifest.get("toolchain")
    lines = [
        "cjdoc native GC diagnostic capture",
        "=" * 34,
        "",
        "This capture is diagnostic evidence only. It is not an acceptance gate,",
        "not a release retry and not a fix. A completed collection, including a",
        "clean exit, does not mean the observed failure is understood or fixed.",
        "",
        f"workflow revision : {manifest['workflowSha']}",
        f"workflow run      : {manifest['workflowRun']['runId']}"
        f" attempt {manifest['workflowRun']['runAttempt']}",
        f"subject commit    : {manifest['subject']['commit']}",
        f"subject tree      : {manifest['subject']['tree']}",
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
    recipe = manifest["runtimeRecipe"]
    assert isinstance(recipe, dict)
    lines.extend([
        f"runtime recipe    : heap {recipe['heap']}, default heuristic GC timing,"
        f" jobs {recipe['jobs']}, cache {recipe['cache']}",
        "",
        f"outcome           : {capture['outcome']}",
        f"complete          : {'yes' if capture['complete'] else 'no'}",
        f"capture status    : {manifest['status']}",
        f"collector exit    : {manifest['collectorExitCode']}",
        "",
    ])
    detail = capture.get("detail")
    if detail:
        lines.extend([f"detail            : {detail}", ""])
    if capture["complete"]:
        lines.append(
            "fault observed    : " + ("yes" if capture["faultObserved"] else
                                       "no (the child exited naturally)"))
        if capture["faultObserved"]:
            lines.append(f"fault signal      : {capture['stopSignal']}")
            lines.append(
                "core captured     : " + ("yes" if capture["coreCaptured"] else "no"))
            lines.append(
                "next step         : run analysis on the decrypted private payload;"
                " this summary does not name a cause")
        else:
            lines.append("natural exit code : " + str(capture["naturalExitCode"]))
            lines.append(
                "next step         : record a clean observation; the original"
                " failure remains open")
        report = capture.get("gcReport")
        if isinstance(report, dict):
            lines.append(
                f"GC report         : {report['retainedBytes']} of "
                f"{report['receivedBytes']} bytes retained"
                + (", truncated at the retention bound" if report["truncated"] else ""))
        reported = recipe.get("reported")
        if isinstance(reported, dict) and reported.get("bannerPresent"):
            lines.append(
                f"reported GC recipe: heap {reported['heap']},"
                f" GC threshold {reported['gcThreshold']},"
                f" interval {reported['gcInterval']},"
                f" backup {reported['backupGcInterval']}")
        else:
            lines.append(
                "reported GC recipe: the runtime printed no parameter banner"
                " before the capture ended")
        normal = manifest.get("normalOutput")
        if isinstance(normal, dict):
            lines.append(f"documents sha256  : {normal['sha256']}")
            lines.append(f"declarations      : {normal['declarationCount']}")
        lines.extend([
            "",
            "No raw debugger output, GC report, core or environment is in this",
            "public set. The complete payload is in private-evidence.p7m and can",
            "only be read with the corresponding private key.",
            "",
        ])
    lines.extend([
        "evidence bundle   : private-evidence.p7m",
        f"ciphertext sha256 : {manifest['evidence']['ciphertextSha256']}",
        f"certificate sha256: {manifest['evidence']['certificateSha256']}",
        "",
        "Capture status 11 preserves the native fault even when evidence collection",
        "succeeds. No capture outcome replaces the original release acceptance gate.",
    ])
    return "\n".join(lines) + "\n"


def parse_arguments(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Run the recovered candidate once under GDB and publish encrypted "
            "diagnostic evidence. Not an acceptance gate."),
    )
    parser.add_argument("--subject", required=True, type=Path,
                        help="checkout of the exact frozen subject commit")
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

    started_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    output = Path(os.path.abspath(os.fspath(arguments.output)))
    if output.is_symlink() or output.exists():
        raise SystemExit("--output must be a fresh, non-existent directory")
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    os.chmod(output, 0o700)
    private = output / "private"
    private.mkdir(mode=0o700)
    (private / "tmp").mkdir(mode=0o700)
    (private / "home").mkdir(mode=0o700)

    manifest: dict[str, object] = {
        "schemaVersion": SCHEMA,
        "kind": "diagnostic-capture",
        "notAcceptance": True,
        "workflowSha": arguments.workflow_sha,
        "workflowRun": {
            "runId": arguments.run_id,
            "runAttempt": arguments.run_attempt,
        },
        "subject": {"commit": SUBJECT_COMMIT, "tree": SUBJECT_TREE},
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
        },
        "runtimeRecipe": {
            "heap": HEAP,
            "gcThreshold": "default",
            "gcInterval": "default",
            "backupGcInterval": "default",
            "jobs": JOBS,
            "cache": "disabled",
            "cpu": "lowest allowed cpu",
            "maximumGenerateInvocations": 1,
            "deadlineSeconds": DIAGNOSTIC_DEADLINE_SECONDS,
            "graceSeconds": GDB_GRACE_SECONDS,
            "reportRetentionBytes": MAX_REPORT_BYTES,
        },
        "capture": {
            "outcome": "incomplete",
            "complete": False,
            "faultObserved": False,
            "stopSignal": None,
            "coreCaptured": False,
            "naturalExitCode": None,
            "deadlineReached": False,
            "detail": None,
            "gcReport": None,
        },
        "evidence": {
            "certificateSha256": CERTIFICATE_SHA256,
            "ciphertextSha256": None,
            "ciphertextBytes": None,
            "members": [],
            "cipher": "openssl cms -encrypt -binary -aes256 -outform DER",
        },
        "status": EXIT_INCOMPLETE,
        "startedAt": started_at,
        "finishedAt": None,
    }
    evidence_payloads: list[tuple[str, Path]] = []
    input_state: dict[str, object] | None = None
    status = EXIT_INCOMPLETE
    capture = manifest["capture"]
    assert isinstance(capture, dict)

    try:
        subject = require_directory(
            Path(os.path.abspath(os.fspath(arguments.subject))), "subject checkout")
        identity = exact_worktree_identity(subject, expected_commit=SUBJECT_COMMIT)
        if identity["tree"] != SUBJECT_TREE:
            raise Incomplete("subject tree differs from the frozen subject")
        before = {
            "headCommit": identity["headCommit"],
            "tree": identity["tree"],
            "worktreeSha256": identity["worktreeSha256"],
        }

        archive = require_regular_file(
            Path(os.path.abspath(os.fspath(arguments.candidate_tar))),
            "candidate archive")
        archive_metadata = archive.stat()
        if archive_metadata.st_size != CANDIDATE_TAR_BYTES:
            raise Incomplete("candidate archive size differs from the pin")
        if sha256_file(archive) != CANDIDATE_TAR_SHA256:
            raise Incomplete("candidate archive digest differs from the pin")

        candidate_root = private / "candidate"
        candidate_root.mkdir(mode=0o700)
        extracted: dict[str, dict[str, object]] = {}
        extract_candidate(archive, candidate_root, extracted)
        main_binary = candidate_root / "target/release/bin/main"
        build_manifest = verify_build_manifest(
            candidate_root / "target/ci-build/build-manifest.json")
        manifest["candidate"]["buildManifest"] = build_manifest

        certificate = require_regular_file(
            Path(os.path.abspath(os.fspath(arguments.certificate))),
            "public encryption certificate")
        if sha256_file(certificate) != CERTIFICATE_SHA256:
            raise Incomplete("the encryption certificate differs from the pin")
        certificate_bytes = certificate.read_bytes()
        if b"PRIVATE KEY" in certificate_bytes:
            raise Incomplete("the encryption input must not be a private key")

        sdk_root = Path(os.path.abspath(os.fspath(arguments.sdk_root)))
        runtime_path = os.pathsep.join([
            str(sdk_root / "bin"), str(sdk_root / "tools" / "bin"),
            str(Path(sys.executable).parent), "/usr/local/bin", "/usr/bin", "/bin",
        ])
        base_environment = minimal_environment(runtime_path)
        base_environment["CANGJIE_HOME"] = str(sdk_root)
        base_environment["CANGJIE_SDK_ROOT"] = str(sdk_root)
        base_environment["CJDOC_PYTHON"] = sys.executable
        compiler_environment = dict(base_environment)
        compiler_environment["HOME"] = str(private / "home")
        compiler_environment["TMPDIR"] = str(private / "tmp")
        compiler_environment["TMP"] = str(private / "tmp")
        compiler_environment["TEMP"] = str(private / "tmp")
        sidecar = os.environ.get("CANGJIE_STDX_PATH", "")
        if not sidecar:
            raise Incomplete(
                "the authenticated static stdx sidecar was not supplied by the "
                "SDK wrapper")
        sdk = verify_sdk(sdk_root, Path(os.path.abspath(sidecar)),
                         compiler_environment)
        native_directory = sdk["nativeDirectory"]
        assert isinstance(native_directory, Path)
        tools_directory = sdk["toolsDirectory"]
        assert isinstance(tools_directory, Path)
        allowlisted = dict(compiler_environment)
        allowlisted["LD_LIBRARY_PATH"] = os.pathsep.join(
            [str(native_directory), str(tools_directory)])
        input_state = {
            "subject": subject,
            "before": before,
            "extracted": extracted,
            "candidateRoot": candidate_root,
            "nativeDirectory": native_directory,
        }
        verify_ldd(main_binary, sdk, allowlisted)
        allowlisted.update({
            "CANGJIE_STDX_PATH": str(Path(sidecar).resolve()),
            "CJDOC_STDX_PATH": str(Path(sidecar).resolve()),
            "CJDOC_STDX_VARIANT": "static",
            "CJDOC_STDX_DIGEST": STDX_DIGEST,
            "CJDOC_TOOLCHAIN_VERSION": SDK_VERSION,
            "CJDOC_TOOLCHAIN_TARGET": SDK_TARGET,
            "CJDOC_TOOLCHAIN_FINGERPRINT": SDK_FINGERPRINT,
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

        version_run = run_checked(
            [str(main_binary), "--version"], env=allowlisted, timeout=120)
        if version_run.returncode != 0:
            raise Incomplete("the recovered binary did not report its version")
        reported = (version_run.stdout + version_run.stderr).strip().splitlines()
        if CANDIDATE_VERSION_OUTPUT not in reported:
            raise Incomplete("the recovered binary is not the frozen release")

        gdb = shutil.which("gdb", path="/usr/local/bin:/usr/bin:/bin")
        if gdb is None:
            raise Incomplete("gdb is not installed")
        openssl = shutil.which("openssl", path="/usr/local/bin:/usr/bin:/bin")
        if openssl is None:
            raise Incomplete("openssl is not installed")
        taskset = shutil.which("taskset", path="/usr/local/bin:/usr/bin:/bin")
        if taskset is None:
            raise Incomplete("taskset is not installed")
        cpu = minimum_allowed_cpu()

        gdb_directory = private / "gdb"
        gdb_directory.mkdir(mode=0o700)
        capture_path = private / "capture.json"
        core_path = private / "core.bin"
        script_path = gdb_directory / "capture.gdb"
        script_path.write_text(gdb_script_text(capture_path, core_path),
                               encoding="utf-8")
        os.chmod(script_path, 0o600)
        gdb_log = gdb_directory / "gdb.log"

        run_root = private / "run"
        report_directory = private / "report"
        report_directory.mkdir(mode=0o700)
        report_path = report_directory / "gc-report.log"
        drainer = ReportDrainer(
            report_directory / "runtime-report.pipe", report_path,
            MAX_REPORT_BYTES)
        drainer.start()

        child_environment = dict(allowlisted)
        child_environment["GITHUB_WORKSPACE"] = str(subject)
        child_environment["GITHUB_SHA"] = SUBJECT_COMMIT
        child_environment["cjHeapSize"] = HEAP
        child_environment["MRT_REPORT"] = str(drainer.fifo)
        command = [
            taskset, "-c", str(cpu), gdb,
            "-q", "-nx", "--batch", "--return-child-result",
            "-x", str(script_path),
            "--args", str(main_binary),
            "generate",
            "--project", str(subject),
            "--format", "json",
            "--output", str(run_root),
            "--jobs", str(JOBS),
            "--no-cache",
        ]
        manifest["invocation"] = {
            "program": "gdb",
            "generateInvocations": 1,
            "cpu": cpu,
            "heap": HEAP,
            "jobs": JOBS,
            "cacheDisabled": True,
            "environmentKeys": sorted(child_environment),
        }
        started = time.monotonic()
        deadline_reached = False
        gdb_exit: int | None = None
        try:
            with gdb_log.open("xb") as log_stream:
                os.chmod(gdb_log, 0o600)
                try:
                    child = subprocess.Popen(
                        command, cwd=str(subject), env=child_environment,
                        stdin=subprocess.DEVNULL, stdout=log_stream,
                        stderr=subprocess.STDOUT, start_new_session=True,
                    )
                except OSError as error:
                    raise Incomplete(
                        f"the debugger could not be started: {error}") from error
                try:
                    gdb_exit = child.wait(timeout=DIAGNOSTIC_DEADLINE_SECONDS)
                except subprocess.TimeoutExpired:
                    deadline_reached = True
                    try:
                        os.kill(child.pid, signal.SIGINT)
                    except ProcessLookupError:
                        pass
                    try:
                        gdb_exit = child.wait(timeout=GDB_GRACE_SECONDS)
                    except subprocess.TimeoutExpired:
                        gdb_exit = None
                if gdb_exit is None:
                    for sent_signal, wait_seconds in ((signal.SIGTERM, 10),
                                                      (signal.SIGKILL, 30)):
                        try:
                            os.killpg(os.getpgid(child.pid), sent_signal)
                        except (ProcessLookupError, PermissionError):
                            pass
                        try:
                            gdb_exit = child.wait(timeout=wait_seconds)
                            break
                        except subprocess.TimeoutExpired:
                            gdb_exit = None
        finally:
            elapsed = time.monotonic() - started
            try:
                report = drainer.finish()
            except Incomplete as error:
                report = {
                    "receivedBytes": drainer.received,
                    "retainedBytes": drainer.retained,
                    "truncated": drainer.received > drainer.retained,
                    "sha256": None,
                    "error": sanitize_detail(str(error)),
                }
        manifest["timing"] = {
            "elapsedSeconds": round(elapsed, 3),
            "deadlineReached": deadline_reached,
        }
        capture["gcReport"] = report
        capture["deadlineReached"] = deadline_reached
        capture["gdbExitCode"] = gdb_exit
        manifest["runtimeRecipe"]["reported"] = (
            verify_report_recipe(report_path) if report_path.is_file()
            else {"bannerPresent": False})
        observed = None
        if capture_path.is_file() and capture_path.stat().st_size > 0:
            try:
                observed = json.loads(capture_path.read_text(encoding="utf-8"))
            except ValueError:
                observed = None
        if not isinstance(observed, dict):
            observed = None
        if observed is not None:
            capture["stopSignal"] = observed.get("stopSignal") or None
            capture["naturalExitCode"] = observed.get("exitCode")
            capture["inferiorPid"] = observed.get("inferiorPid")
            capture["runError"] = (
                sanitize_detail(observed["runError"])
                if isinstance(observed.get("runError"), str) else None)
            capture["coreAttempted"] = observed.get("coreAttempted")
            capture["coreError"] = (
                sanitize_detail(observed["coreError"])
                if isinstance(observed.get("coreError"), str) else None)
        capture["coreCaptured"] = core_path.is_file() and core_path.stat().st_size > 0
        capture["gdb"] = summarize_gdb_log(gdb_log)
        # Everything the run produced is packaged before the outcome is
        # classified, so an incomplete run still carries its reachable evidence.
        evidence_payloads.extend([
            ("gdb.log", gdb_log),
            ("gc-report.log", report_path),
            ("capture.gdb", script_path),
        ])
        if capture_path.is_file() and capture_path.stat().st_size > 0:
            evidence_payloads.append(("capture.json", capture_path))
        if capture["coreCaptured"]:
            evidence_payloads.append(("core.bin", core_path))
        if report.get("error") or report["truncated"]:
            raise Incomplete("the runtime GC report is incomplete")

        stop_signal = capture["stopSignal"]
        natural_exit = capture["naturalExitCode"]
        deadline_interrupt = (
            deadline_reached and isinstance(stop_signal, str)
            and stop_signal.endswith("SIGINT"))
        if deadline_reached:
            status = EXIT_DEADLINE
            capture["outcome"] = (
                "deadlineReachedWithFaultCapture"
                if capture["coreCaptured"] and stop_signal and not deadline_interrupt
                else "deadlineReached")
            capture["complete"] = False
            capture["faultObserved"] = bool(
                stop_signal and not deadline_interrupt)
            capture["detail"] = (
                "the diagnostic deadline expired; SIGINT capture grace was applied "
                "and the process group was terminated afterwards")
        elif observed is None:
            status = EXIT_GDB_FAILURE
            capture["outcome"] = "noCaptureProduced"
            capture["detail"] = (
                "the debugger produced no capture record; the run is not usable")
        elif natural_exit is not None:
            capture["naturalExitCode"] = int(natural_exit)
            if int(natural_exit) == 0:
                documents = run_root / "docs.json"
                if not documents.is_file():
                    raise Incomplete(
                        "the child exited cleanly but produced no documents")
                documents_sha = sha256_file(documents)
                try:
                    payload = json.loads(documents.read_text(encoding="utf-8"))
                    declarations = payload.get("declarations")
                    if not isinstance(declarations, list):
                        raise Incomplete("the produced documents are malformed")
                    count = len(declarations)
                except ValueError as error:
                    raise Incomplete(
                        f"the produced documents are unreadable: {error}") from error
                if documents_sha != NORMAL_DOCS_SHA256:
                    raise Incomplete(
                        "the produced documents differ from the original normal output")
                if count != NORMAL_DECLARATION_COUNT:
                    raise Incomplete(
                        "the produced declaration count differs from the original")
                manifest["normalOutput"] = {
                    "sha256": documents_sha,
                    "declarationCount": count,
                }
                status = EXIT_COMPLETE_NORMAL
                capture["complete"] = True
                capture["faultObserved"] = False
                capture["outcome"] = "naturalExitNoFaultObserved"
                capture["detail"] = (
                    "no fault was observed in this single capture; the original "
                    "failure is neither reproduced nor fixed")
            else:
                status = EXIT_INCOMPLETE
                capture["outcome"] = "childExitedNaturallyNonZero"
                capture["detail"] = (
                    "the child exited with a non-zero status without a captured "
                    f"signal (status {int(natural_exit)})")
        elif stop_signal:
            capture["faultObserved"] = True
            if capture["coreCaptured"]:
                status = EXIT_COMPLETE_FAULT
                capture["complete"] = True
                capture["outcome"] = "faultCaptured"
                capture["detail"] = (
                    "a fault and its core were captured; this capture does not "
                    "identify a root cause or fix the failure")
            else:
                status = EXIT_GDB_FAILURE
                capture["outcome"] = "faultWithoutCore"
                capture["detail"] = (
                    "the child stopped on a signal but no core was produced")
        else:
            status = EXIT_GDB_FAILURE
            capture["outcome"] = "captureWithoutOutcome"
            capture["detail"] = (
                "the capture record has neither a natural exit nor a stop signal")

        # The source tree, the recovered binaries and the pinned native
        # libraries must be unchanged by the capture.
        check_inputs_unchanged(input_state)
        record_input_state(manifest, input_state)
    except Incomplete as error:
        detail = sanitize_detail(str(error))
        capture["complete"] = False
        if capture["outcome"] == "incomplete":
            capture["outcome"] = "incompletePrerequisite"
        else:
            capture["outcome"] = f"{capture['outcome']}ButIncomplete"
        existing = capture.get("detail")
        capture["detail"] = (
            f"{existing}; {detail}" if existing else detail)
        status = EXIT_INCOMPLETE
        # Even an incomplete run must state whether its inputs survived.
        record_input_state(manifest, input_state)

    manifest["status"] = status
    manifest["finishedAt"] = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime()) + "Z"

    # Gather whatever evidence this run actually reached before sealing it: an
    # incomplete run must still carry the logs and core it produced.
    collect_evidence_payloads(private, evidence_payloads)
    private_manifest = json.loads(json.dumps(manifest))
    private_manifest["capture"] = dict(capture)
    private_manifest["heldOut"] = (
        "raw debugger output, GC report, core and this manifest are private")
    private_manifest_path = private / "private-manifest.json"
    write_private_json(private_manifest_path, private_manifest)
    os.chmod(private_manifest_path, 0o600)
    payloads = [("private-manifest.json", private_manifest_path), *evidence_payloads]
    deduplicated: list[tuple[str, Path]] = []
    seen_names: set[str] = set()
    for name, path in payloads:
        if name in seen_names or not path.is_file():
            continue
        seen_names.add(name)
        deduplicated.append((name, path))

    openssl = shutil.which("openssl", path="/usr/local/bin:/usr/bin:/bin")
    try:
        if not deduplicated:
            raise Incomplete("no evidence payload was collected")
        if openssl is None:
            raise Incomplete("openssl is not installed")
        archive_path = private / "evidence.tar.gz"
        deterministic_archive(deduplicated, archive_path)
        manifest["evidence"]["members"] = verify_archive(
            archive_path, deduplicated)
        manifest["evidence"]["archiveBytes"] = archive_path.stat().st_size
        manifest["evidence"]["archiveSha256"] = sha256_file(archive_path)
        encrypt_environment = minimal_environment("/usr/local/bin:/usr/bin:/bin")
        ciphertext = output / "public" / "private-evidence.p7m"
        ciphertext.parent.mkdir(mode=0o700, exist_ok=True)
        certificate = Path(os.path.abspath(
            os.fspath(arguments.certificate)))
        encrypt_evidence(archive_path, openssl, certificate, ciphertext,
                         encrypt_environment)
        manifest["evidence"]["ciphertextBytes"] = ciphertext.stat().st_size
        manifest["evidence"]["ciphertextSha256"] = sha256_file(ciphertext)
    except Incomplete as error:
        capture["complete"] = False
        existing = capture.get("detail")
        capture["detail"] = (
            f"{existing}; evidence packaging failed: {error}" if existing else
            f"evidence packaging failed: {error}")
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
        item.name for item in (output / "public").iterdir()
        if item.name not in PUBLIC_FILES
    )
    if leaked:
        raise SystemExit(
            "public directory contains a non-allowlisted entry: " + leaked[0])
    print(json.dumps({
        "schemaVersion": SCHEMA,
        "status": manifest["status"],
        "outcome": capture["outcome"],
        "complete": capture["complete"],
        "evidence": manifest["evidence"]["ciphertextSha256"],
        "public": sorted(item.name for item in (output / "public").iterdir()),
    }, sort_keys=True))
    return int(manifest["collectorExitCode"])


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
