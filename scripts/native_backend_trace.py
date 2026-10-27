"""One conditional backend observation; never retry or qualify a product build."""
from __future__ import annotations

from collections import deque
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import re
import shlex
import subprocess

from native_capture_support import digest


COMMON = (
    "--cangjie-pipeline", "-disable-debug-info-print", "--relocation-model=pic",
    "--frame-pointer=non-leaf", "--stack-trace-format=default",
)
FLAGS = {
    "windows-x64": COMMON + (
        "-mcpu=generic", "-mattr=-avx", "--cj-safepoint-outline=false",
        "--mtriple=x86_64-w64-mingw32", "-O2", "--filetype=obj", "-o",
    ),
    "macos-arm64": COMMON + (
        "--cj-stack-grow=false", "--cj-safepoint-outline=false", "-O2",
        "--filetype=obj", "-o",
    ),
}
TRACE_PACKAGES = {
    "dependencies": frozenset({"yjson", "markdown"}),
    "pr166-provider-155": frozenset({"cjdoc", "markdown"}),
}

# These profiles are the complete flags printed in the original failing native
# commands. A changed profile is evidence to inspect, not permission to guess.
ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
EXECUTION = re.compile(
    r"Executing Pass '([^'\r\n]{1,200})' on Function "
    r"'([A-Za-z0-9_.$:<>-]{1,1024})'\.\.\.")
TRACE_LIMIT = 128 * 1024 * 1024


@dataclass(frozen=True)
class TraceRequest:
    platform: str
    tool: Path
    expected_tool_sha256: str
    bitcode: Path
    expected_bitcode_sha256: str
    original_bitcode_path: Path
    build_log: str
    directory: Path
    environment: dict[str, str]
    package: str = "yjson"
    scope: str = "dependencies"


def _command_path(value: str, platform: str) -> str:
    result = re.sub(r"/+", "/", value.replace("\\", "/"))
    return result.casefold() if platform == "windows-x64" else result


def _contains_path(line: str, path: Path, platform: str) -> bool:
    text = _command_path(line, platform)
    name = _command_path(str(path), platform)
    return re.search(r"(?<![A-Za-z0-9_./-])" + re.escape(name)
                     + r"(?=['\"\s]|$)", text) is not None


def observed_profile(request: TraceRequest) -> dict:
    """Validate the complete argv in the unique CJC backend failure diagnostic.

    cjpm --verbose prints the frontend command, not the backend -V output.
    The real failure line is sufficient; do not add -V to the product target.
    Parsed shell text is evidence only and is never executed.
    """
    if request.package not in TRACE_PACKAGES.get(request.scope, frozenset()):
        raise ValueError("backend package is outside the frozen diagnostic scope")
    filename=request.package+".opt.bc"
    rows = [ANSI.sub("", row) for row in request.build_log.splitlines()]
    failures = [row for row in rows if filename in row and "llc" in row
                and "command failed with exit code" in row]
    if not failures:
        raise ValueError("no explicit "+request.package+" llc failure; no backend observation started")
    candidates = [row for row in failures
                  if _contains_path(row, request.tool, request.platform)
                  and _contains_path(row, request.original_bitcode_path, request.platform)]
    if len(failures) != 1 or len(candidates) != 1:
        raise ValueError("unique original backend failure argv unavailable")
    match = re.search(r"error: (.*): command failed with exit code ([0-9]+)(?:\s|$)", candidates[0])
    if match is None:
        raise ValueError("unrecognized original backend failure diagnostic")
    command = match[1].strip()
    if request.platform == "windows-x64":
        if not command.startswith('""') or not command.endswith('"'):
            raise ValueError("unrecognized Windows backend quoting")
        command = command[1:-1].strip()
    argv = shlex.split(command, posix=True)
    loader = None
    if request.platform == "macos-arm64":
        loader = "LD_LIBRARY_PATH=" + str(request.tool.parent / "../lib") + ":$DYLD_LIBRARY_PATH"
        if not argv or argv[0] != loader:
            raise ValueError("backend loader prefix differs from the native profile")
        argv = argv[1:]
    flags = FLAGS[request.platform]
    expected_output = re.sub(re.escape(filename)+r"$", request.package+".o", str(request.original_bitcode_path))
    if expected_output == str(request.original_bitcode_path):
        raise ValueError("original backend input is not "+filename)
    if (len(argv) != len(flags) + 3
            or _command_path(argv[0], request.platform) != _command_path(str(request.tool), request.platform)
            or _command_path(argv[1], request.platform) != _command_path(str(request.original_bitcode_path), request.platform)
            or tuple(argv[2:-1]) != flags
            or _command_path(argv[-1], request.platform) != _command_path(expected_output, request.platform)):
        raise ValueError("backend argv differs from the complete frozen native profile")
    return {"originalPackage":request.package, "originalFlags": list(flags), "originalFailureExitCode": int(match[2]),
            "originalLoaderExpression": loader,
            "originalFailureLineSha256": hashlib.sha256(candidates[0].encode()).hexdigest()}


def observations(stderr: Path) -> dict:
    """Publish bounded pass/function observations, not raw IR or a full dump."""
    last = None
    records = deque(maxlen=64)
    count = 0
    unknown = 0
    errors = []
    if stderr.stat().st_size > TRACE_LIMIT:
        return {"status": "TRACE_TOO_LARGE", "byteLimit": TRACE_LIMIT,
                "lastRecordedExecution": None, "executionRecords": []}
    with stderr.open(encoding="utf-8", errors="replace") as stream:
        for line in stream:
            if "Executing Pass" in line:
                count += 1
                match = EXECUTION.search(line)
                if match:
                    last = {"pass": match[1], "function": match[2]}
                    records.append(last)
                else:
                    unknown += 1
                    last = None
            if len(errors) < 16 and line.lstrip().startswith(
                    ("LLVM ERROR:", "Exception Code:", "error:", "llc:")):
                errors.append(line.rstrip()[:512])
    return {"status": "OBSERVED", "executionLineCount": count,
            "unparsedExecutionLines": unknown, "lastRecordedExecution": last,
            "executionRecords": list(records), "diagnosticErrorLines": errors,
            "meaning": "Last logged execution, not an independently proven fault location"}


def trace_once(request: TraceRequest, runner=subprocess.run) -> dict:
    profile = observed_profile(request)
    if request.bitcode.is_symlink() or not request.bitcode.is_file():
        raise ValueError("backend observation input must be retained regular bitcode")
    if digest(request.bitcode) != request.expected_bitcode_sha256:
        raise ValueError("retained bitcode differs before backend observation")
    if digest(request.tool) != request.expected_tool_sha256:
        raise ValueError("SDK llc differs before backend observation")
    # The new directory is also the exclusive attempt marker. Never reuse it.
    request.directory.mkdir(mode=0o700)
    output = request.directory / "observed.o"
    command = [str(request.tool), str(request.bitcode), *FLAGS[request.platform][:-1],
               "-o", str(output), "--debug-pass=Executions"]
    environment = request.environment.copy()
    if profile["originalLoaderExpression"] is not None:
        # Reproduce the known loader assignment without executing shell text.
        # This expands the controller's inherited value, not an OS-level
        # observation of the original backend environment.
        environment["LD_LIBRARY_PATH"] = (str(request.tool.parent / "../lib") + ":"
                                          + environment.get("DYLD_LIBRARY_PATH", ""))
    stdout = request.directory / "stdout.raw"
    stderr = request.directory / "stderr.raw"
    code = None
    timed_out = False
    launch_error = None
    (request.directory / "attempt.json").write_text(json.dumps({
        "attempts": 1, "argv": command, "state": "launch requested"}, indent=2) + "\n")
    with stdout.open("xb") as out, stderr.open("xb") as err:
        try:
            result = runner(command, env=environment, cwd=request.directory,
                            stdout=out, stderr=err, timeout=600, check=False)
            code = result.returncode
        except subprocess.TimeoutExpired:
            # subprocess.run kills and waits for this standalone llc process.
            # It does not launch a second attempt or change the product result.
            timed_out = True
        except OSError as error:
            launch_error = type(error).__name__ + ": " + str(error)
    stable = (digest(request.bitcode) == request.expected_bitcode_sha256
              and digest(request.tool) == request.expected_tool_sha256)
    result = {"diagnosticOnly": True, "backendInvocations": 0 if launch_error else 1,
            "backendAttempts": 1, "launchError": launch_error, "argv": command,
            **profile, "extraObservationFlags": ["--debug-pass=Executions"],
            "loaderExpansionBasis": "Controller inherited environment; original backend environment not observed",
            "rawInputSha256": request.expected_bitcode_sha256,
            "llcSha256": request.expected_tool_sha256, "exitCode": code,
            "timedOut": timed_out, "timeoutSeconds": 600, "inputsUnchanged": stable,
            "stdoutSha256": digest(stdout), "stderrSha256": digest(stderr),
            "stdoutBytes": stdout.stat().st_size, "stderrBytes": stderr.stat().st_size,
            "observations": observations(stderr), "rawTracePublished": False,
            "qualification": False,
            "scope": "One backend observation after the original failed product command"}
    (request.directory / "result.raw.json").write_text(json.dumps(result, indent=2) + "\n")
    return result
