"""Linux-only, exact-input consumer verification for the frozen Agent experiment."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
from contextlib import ExitStack
import signal
import subprocess
import struct
import sys
import time
import tomllib

import capture_build_context

STREAM_BYTES = 65536
FILE_BYTES = 64 * 1024 * 1024
ADDRESS_BYTES = 64 * 1024 * 1024 * 1024
DATA_BYTES = 4 * 1024 * 1024 * 1024


def runtime_seccomp_filter() -> bytes:
    # Linux x86-64 ABI only. Reject process creation and new namespaces while
    # allowing pthread clone flags; clone3 returns ENOSYS for libc fallback.
    if os.uname().machine != "x86_64":
        raise RuntimeError("consumer sandbox filter requires Linux x86-64")
    deny = 0x00050000 | 1
    instructions = [(0x20, 0, 0, 4), (0x15, 1, 0, 0xC000003E),
                    (0x06, 0, 0, 0x80000000), (0x20, 0, 0, 0),
                    (0x45, 0, 1, 0x40000000), (0x06, 0, 0, deny)]
    for number in (57, 58, 272, 308):
        instructions += [(0x15, 0, 1, number), (0x06, 0, 0, deny)]
    instructions += [(0x15, 0, 1, 435), (0x06, 0, 0, 0x00050000 | 38),
                     (0x15, 0, 3, 56), (0x20, 0, 0, 16),
                     (0x45, 1, 0, 0x10000), (0x06, 0, 0, deny),
                     (0x06, 0, 0, 0x7FFF0000)]
    return b"".join(struct.pack("HBBI", *instruction) for instruction in instructions)
HARNESS = "agent_evaluation_build"


def sha(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def stream_record(path: Path, labels) -> dict:
    with path.open("rb") as stream:
        content = stream.read(STREAM_BYTES)
    size = path.stat().st_size
    return {"text": labels.text(content.decode("utf-8", "replace")),
            "bytes": size, "sha256": sha(path), "truncated": size > STREAM_BYTES,
            "path": labels.text(str(path))}


def terminate_group(process: subprocess.Popen) -> None:
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()


def run_process(command: list[str], cwd: Path, environment: dict[str, str],
                seconds: float, logs: Path, labels, *, pass_fds: tuple = ()) -> dict:
    logs.mkdir(mode=0o700, parents=True, exist_ok=True)
    stdout, stderr = logs / "stdout", logs / "stderr"
    started = time.monotonic()
    code = None
    expired = False
    launch_error = None
    with stdout.open("wb") as out, stderr.open("wb") as err:
        try:
            process = subprocess.Popen(command, cwd=cwd, env=environment,
                stdin=subprocess.DEVNULL, stdout=out, stderr=err,
                start_new_session=True, close_fds=True, pass_fds=pass_fds)
        except OSError as error:
            launch_error = labels.text(str(error))
        else:
            try:
                code = process.wait(timeout=seconds)
            except subprocess.TimeoutExpired:
                expired = True
                terminate_group(process)
                code = process.returncode
            finally:
                terminate_group(process)
    return {"command": labels.command(command), "cwd": labels.text(str(cwd)),
            "exitCode": code, "timedOut": expired, "launchError": launch_error,
            "elapsedMs": round((time.monotonic() - started) * 1000, 3),
            "stdout": stream_record(stdout, labels), "stderr": stream_record(stderr, labels)}


class ConsumerRuntime:
    """Fixed compiler/runtime mounts; no inherited credentials or unsafe fallback."""

    def __init__(self, sdk: Path, labels):
        if not sys.platform.startswith("linux"):
            raise RuntimeError("consumer verification requires Linux namespaces")
        self.sdk = sdk.resolve(strict=True)
        self.labels = labels
        self.cjc = self.sdk / "bin/cjc"
        self.cjpm = self.sdk / "tools/bin/cjpm"
        self.bwrap = shutil.which("bwrap")
        self.prlimit = shutil.which("prlimit")
        if not self.bwrap or not self.prlimit or not self.cjc.is_file() or not self.cjpm.is_file():
            raise RuntimeError("pinned compiler, cjpm, bwrap and prlimit are required")
        self.runtime_directories = sorted(path for path in (self.sdk / "runtime/lib").iterdir()
                                          if path.is_dir() and path.name.endswith("_cjnative"))
        if not self.runtime_directories:
            raise RuntimeError("matching Cangjie runtime libraries are missing")

    def environment(self, scratch: Path, compiler: bool) -> dict[str, str]:
        libraries = list(self.runtime_directories)
        if compiler:
            libraries.append(self.sdk / "tools/lib")
        return {"PATH": (str(self.sdk / "bin") + ":" + str(self.sdk / "tools/bin") + ":"
                         if compiler else "") + "/usr/bin:/bin",
                "HOME": str(scratch / "home"), "TMPDIR": str(scratch / "tmp"),
                "TMP": str(scratch / "tmp"), "TEMP": str(scratch / "tmp"),
                "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8", "TZ": "UTC",
                "LD_LIBRARY_PATH": ":".join(map(str, libraries)),
                "CANGJIE_HOME": str(self.sdk) if compiler else "",
                "cjHeapSize": "512MB"}

    def execute(self, command: list[str], *, cwd: Path, scratch: Path,
                readonly: list[Path], writable: list[Path], compiler: bool,
                seconds: float, logs: Path) -> dict:
        for relative in ("home", "tmp", "work"):
            (scratch / relative).mkdir(mode=0o700, parents=True, exist_ok=True)
        environment = self.environment(scratch, compiler)
        argv = [self.bwrap, "--unshare-all", "--die-with-parent", "--new-session",
                "--cap-drop", "ALL", "--clearenv", "--tmpfs", "/"]
        for path in ("/usr", "/bin", "/sbin", "/lib", "/lib64", "/etc/ld.so.cache"):
            if Path(path).exists():
                argv += ["--ro-bind", path, path]
        argv += ["--proc", "/proc", "--dev", "/dev"]
        sdk_mounts = [self.sdk] if compiler else [self.sdk / "runtime/lib"]
        for path in sdk_mounts:
            argv += ["--ro-bind", str(path), str(path)]
        if not compiler and writable:
            raise RuntimeError("runtime filesystem writes are not admitted by the frozen tasks")
        for path in [scratch, *writable]:
            argv += ["--bind" if compiler else "--ro-bind", str(path), str(path)]
        argv += ["--bind" if compiler else "--ro-bind", str(scratch / "tmp"), "/tmp"]
        if not compiler:
            argv += ["--remount-ro", "/dev"]
        for path in readonly:
            argv += ["--ro-bind", str(path), str(path)]
        for key, value in sorted(environment.items()):
            argv += ["--setenv", key, value]
        with ExitStack() as descriptors:
            pass_fds = ()
            if not compiler:
                filter_path = scratch / "runtime.seccomp"
                filter_path.write_bytes(runtime_seccomp_filter())
                descriptor = descriptors.enter_context(filter_path.open("rb"))
                pass_fds = (descriptor.fileno(),)
                argv += ["--seccomp", str(descriptor.fileno())]
            argv += ["--remount-ro", "/", "--chdir", str(cwd), "--", self.prlimit,
                     f"--as={ADDRESS_BYTES}", f"--data={DATA_BYTES}", f"--fsize={FILE_BYTES}",
                     "--nofile=256", "--nproc=256", "--core=0", "--", *command]
            # The namespace supervisor itself also gets no invoking credentials.
            receipt = run_process(argv, cwd, {"PATH": "/usr/bin:/bin"}, seconds, logs,
                                  self.labels, pass_fds=pass_fds)
        receipt["command"] = self.labels.command(command)
        receipt["sandbox"] = {"provider": "bwrap", "network": "unshared",
            "inheritedEnvironment": False, "hostHomeMounted": False,
            "compilerMounted": compiler, "rootReadOnly": True,
            "diskBackedTemporaryDirectory": True, "addressSpaceBytesPerProcess": ADDRESS_BYTES,
            "maximumDataBytesPerProcess": DATA_BYTES, "maximumFileBytes": FILE_BYTES,
            "aggregateScratchQuota": None, "writableFilesystemRoots": compiler,
            "newProcessesAllowed": compiler}
        return receipt

    def preflight(self, root: Path) -> dict:
        scratch = root / "scratch"
        receipt = self.execute([str(self.cjc), "-v"], cwd=root, scratch=scratch,
            readonly=[], writable=[], compiler=True, seconds=30, logs=root / "logs")
        if receipt["exitCode"] != 0 or receipt["timedOut"] or receipt["launchError"]:
            raise RuntimeError("compiler namespace preflight failed: " + receipt["stderr"]["text"])
        return receipt


def source_closure(project_root: Path, roots: list[Path]) -> list[dict]:
    captured = {}
    project_root = project_root.resolve(strict=True)

    def visit(root: Path):
        root = root.resolve(strict=True)
        if not root.is_relative_to(project_root):
            raise RuntimeError("dependency is outside the frozen source capture")
        if root in captured:
            return
        manifest = tomllib.loads((root / "cjpm.toml").read_text("utf-8"))
        files = {}
        identity = capture_build_context.identity(root, file_digests=files)
        captured[root] = {"root": root, "relative": root.relative_to(project_root),
                          "identity": identity, "files": files,
                          "name": manifest["package"]["name"],
                          "version": manifest["package"].get("version", "")}
        for value in manifest.get("dependencies", {}).values():
            if not isinstance(value, dict) or "path" not in value:
                raise RuntimeError("verification requires a captured local path-dependency closure")
            visit(root / value["path"])
    for root in roots:
        visit(root)
    return list(captured.values())


def snapshot_closure(project_root: Path, roots: list[Path], destination: Path) -> list[dict]:
    closure = source_closure(project_root, roots)
    for item in closure:
        copied = destination / item["relative"]
        copied.mkdir(mode=0o700, parents=True, exist_ok=True)
        for relative, expected in item["files"].items():
            source = item["root"] / relative
            target = copied / relative
            target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            if sha(source) != expected:
                raise RuntimeError("captured source changed before snapshot")
            shutil.copyfile(source, target)
            if sha(target) != expected or sha(source) != expected:
                raise RuntimeError("captured source changed during snapshot")
        if capture_build_context.identity(copied) != item["identity"]:
            raise RuntimeError("dependency snapshot identity differs from frozen source")
    return closure


def capture_exports(release: Path, destination: Path) -> dict:
    directories, libraries, pins = set(), set(), []
    destination.mkdir(mode=0o700, parents=True)
    for path in sorted(release.rglob("*")):
        relative = path.relative_to(release)
        if any(part.startswith(".") or part in ("bin", "unittest_bin") for part in relative.parts):
            continue
        if path.is_symlink():
            raise RuntimeError("symbolic compiler artifact refused")
        if not path.is_file() or path.suffix not in (".cjo", ".a"):
            continue
        if path.stem in (HARNESS, "lib" + HARNESS):
            continue
        before = sha(path)
        copied = destination / relative
        copied.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        shutil.copyfile(path, copied)
        if sha(path) != before or sha(copied) != before:
            raise RuntimeError("compiler export changed during capture")
        directories.add(copied.parent)
        pins.append({"path": relative.as_posix(), "sha256": before, "bytes": copied.stat().st_size})
        if path.name.startswith("lib") and path.suffix == ".a":
            name = path.name[3:-2]
            if any(character not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-" for character in name):
                raise RuntimeError("unsupported static archive name")
            libraries.add(name)
    if not pins or not libraries:
        raise RuntimeError("no public static dependency exports were produced")
    return {"root": destination, "directories": sorted(directories), "libraries": sorted(libraries), "pins": pins}


def validate_export_pins(exports: dict) -> None:
    pins = exports.get("pins", [])
    if not pins:
        if exports.get("directories") or exports.get("libraries"):
            raise RuntimeError("unpinned compiler exports refused")
        return
    root = Path(exports["root"])
    if root.is_symlink() or not root.is_dir():
        raise RuntimeError("compiler export root changed")
    for pin in pins:
        relative = Path(pin["path"])
        if relative.is_absolute() or ".." in relative.parts:
            raise RuntimeError("compiler export pin escaped its root")
        path = root / relative
        if any(parent.is_symlink() for parent in [path, *path.parents] if parent == root or root in parent.parents):
            raise RuntimeError("symbolic compiler export refused")
        if not path.is_file() or path.stat().st_size != pin["bytes"] or sha(path) != pin["sha256"]:
            raise RuntimeError("captured compiler export changed")
    for directory in exports["directories"]:
        Path(directory).resolve().relative_to(root.resolve())


def build_libraries(runtime: ConsumerRuntime, scope: dict, project_root: Path,
                    root: Path, seconds: float) -> dict:
    if not scope["dependencies"]:
        return {"state": "not_required", "reason": "scope declares no compile dependency",
                "receipt": None, "sources": [],
                "exports": {"directories": [], "libraries": [], "pins": []}}
    sources, harness, target = root / "sources", root / "harness", root / "target"
    closure = snapshot_closure(project_root, [item["root"] for item in scope["dependencies"]], sources)
    (harness / "src").mkdir(mode=0o700, parents=True)
    target.mkdir(mode=0o700)
    package = tomllib.loads((scope["dependencies"][0]["root"] / "cjpm.toml").read_text("utf-8"))["package"]
    manifest = ["[package]", "cjc-version = " + json.dumps(package["cjc-version"]),
                f'name = "{HARNESS}"', 'version = "0.0.0"',
                'output-type = "static"', "", "[dependencies]"]
    for item in scope["dependencies"]:
        path = sources / item["root"].resolve().relative_to(project_root.resolve())
        relative = Path(os.path.relpath(path, harness)).as_posix()
        manifest.append(json.dumps(item["name"]) + " = { path = " + json.dumps(relative) + ', output-type = "static" }')
    (harness / "cjpm.toml").write_text("\n".join(manifest) + "\n", encoding="utf-8")
    (harness / "src/main.cj").write_text(f"package {HARNESS}\n\npublic func marker(): Unit {{}}\n", encoding="utf-8")
    receipt = runtime.execute([str(runtime.cjpm), "build", "--jobs", "1", "--target-dir", str(target)],
        cwd=harness, scratch=root / "scratch", readonly=[sources, harness / "src", harness / "cjpm.toml"],
        writable=[harness, target], compiler=True, seconds=seconds, logs=root / "logs")
    result = {"state": "build-failed", "receipt": receipt,
              "sources": [{"path": item["relative"].as_posix(), "name": item["name"],
                           "version": item["version"], "identity": item["identity"]} for item in closure]}
    for item in closure:
        copied = sources / item["relative"]
        if capture_build_context.identity(copied) != item["identity"] or capture_build_context.identity(item["root"]) != item["identity"]:
            result["failure"] = "source changed through compilation"
            return result
    if receipt["exitCode"] != 0 or receipt["timedOut"] or receipt["launchError"]:
        return result
    result["exports"] = capture_exports(target / "release", root / "exports")
    result["state"] = "built"
    return result


def compile_consumer(runtime: ConsumerRuntime, code: str, root: Path,
                     exports: dict, seconds: float) -> dict:
    validate_export_pins(exports)
    source = root / "input/main.cj"
    source.parent.mkdir(mode=0o700, parents=True)
    source.write_bytes(code.encode("utf-8"))
    expected = hashlib.sha256(code.encode("utf-8")).hexdigest()
    if sha(source) != expected:
        raise RuntimeError("consumer bytes changed before compilation")
    output = root / "out"
    output.mkdir(mode=0o700)
    command = [str(runtime.cjc), "--static", "--output-type", "exe", "-O1",
               "--output-dir", str(output), "-o", "main"]
    for directory in exports["directories"]:
        command += ["--import-path", str(directory), "--library-path", str(directory)]
    command += ["--link-options", "--start-group " +
                " ".join("-l" + name for name in exports["libraries"]) + " --end-group", str(source)]
    receipt = runtime.execute(command, cwd=root / "scratch/work", scratch=root / "scratch",
        readonly=[source.parent, *exports["directories"]], writable=[output], compiler=True,
        seconds=seconds, logs=root / "compile-logs")
    validate_export_pins(exports)
    receipt["inputSha256"] = sha(source)
    if receipt["inputSha256"] != expected:
        raise RuntimeError("consumer bytes changed during compilation")
    binary = output / "main"
    if binary.is_symlink():
        raise RuntimeError("symbolic compiler executable refused")
    return {"packaging": {"kind": "verbatim", "prependedBytes": 0,
            "writtenBytes": source.stat().st_size, "writtenSha256": expected,
            "answerCodeSha256": expected}, "compile": receipt,
            "binary": binary if binary.is_file() else None}


def run_consumer(runtime: ConsumerRuntime, binary: Path, root: Path, seconds: float) -> dict:
    if binary.is_symlink() or not binary.is_file():
        raise RuntimeError("compiled executable changed before runtime")
    digest = sha(binary)
    receipt = runtime.execute([str(binary)], cwd=root / "run-scratch/work",
        scratch=root / "run-scratch", readonly=[binary.parent], writable=[], compiler=False,
        seconds=seconds, logs=root / "run-logs")
    receipt["binarySha256"] = digest
    if sha(binary) != digest:
        raise RuntimeError("compiled binary changed through execution")
    return {"state": "runtime-executed", "run": receipt}
