#!/usr/bin/env python3
"""Run the complete optional-worker contract after the ordinary CI identity gates.

Only a tracked commit archive is writable. The original checkout/binary and its
performance receipts are read-only; Node and build caches stay in a private root.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil

import subprocess
import sys
import tarfile
import time

sys.dont_write_bytecode = True
NODE_VERSION = "v26.11.1"
HIGHLIGHT_VERSION = "11.11.1"
PLATFORMS = {("linux", "x86_64"): "linux-x64", ("darwin", "arm64"): "macos-arm64",
             ("win32", "amd64"): "windows-x64"}


def sha256(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def require_versions(source: Path, node_version: str) -> None:
    package = json.loads((source / "tools/highlight/package.json").read_text(encoding="utf-8"))
    lock = json.loads((source / "tools/highlight/package-lock.json").read_text(encoding="utf-8"))
    if node_version.strip() != NODE_VERSION:
        raise ValueError("optional worker requires exactly Node " + NODE_VERSION)
    if (package["dependencies"].get("highlight.js") != HIGHLIGHT_VERSION or
            lock["packages"]["node_modules/highlight.js"]["version"] != HIGHLIGHT_VERSION):
        raise ValueError("optional worker requires the pinned Highlight.js lock")


def private_directory(path: Path, repo: Path) -> Path:
    path = path.resolve()
    if path.is_relative_to(repo.resolve()):
        raise ValueError("optional worker outputs must be outside the source checkout")
    path.mkdir(mode=0o700, parents=False, exist_ok=False)
    return path


def require_disk_work_root(path: Path) -> None:
    if shutil.disk_usage(path).free < 1024 * 1024 * 1024:
        raise ValueError("optional worker CI needs at least 1 GiB of free disk space")
    if sys.platform.startswith("linux"):
        mounts = []
        for line in Path("/proc/mounts").read_text(encoding="utf-8").splitlines():
            fields = line.split()
            mount = Path(fields[1].replace("\\040", " "))
            if path.is_relative_to(mount):
                mounts.append((len(mount.parts), fields[2]))
        if not mounts or max(mounts)[1] in {"tmpfs", "ramfs"}:
            raise ValueError("optional worker build root must be on a verified disk filesystem")


def failure_facts(error: Exception) -> dict:
    """Public failure facts deliberately exclude exception text, argv and stderr."""
    if isinstance(error, subprocess.TimeoutExpired):
        return {"reason": "step-timeout", "timeoutSeconds": error.timeout}
    if isinstance(error, subprocess.CalledProcessError):
        return {"reason": "step-failed", "exitCode": error.returncode}
    if isinstance(error, OSError):
        return {"reason": "host-io-error", "errno": error.errno}
    return {"reason": "validation-failed"}


def traceback_locations(source: Path, traceback) -> list[dict]:
    """Retain trusted script/line locations, never exception text or locals."""
    allowed = {source.resolve() / name: name for name in (
        "scripts/highlight_acceptance.py", "scripts/highlight_process.py")}
    locations = []
    while traceback is not None and len(locations) < 16:
        script = allowed.get(Path(traceback.tb_frame.f_code.co_filename).resolve())
        if script is not None:
            locations.append({"script": script, "line": traceback.tb_lineno})
        traceback = traceback.tb_next
    return locations


def load_traceback_locations(path: Path) -> list[dict] | None:
    """Validate the child's diagnostic record before publishing any of it."""
    try:
        with path.open("rb") as stream:
            raw = stream.read(8193)
        if len(raw) > 8192:
            return None
        locations = json.loads(raw)
    except (OSError, ValueError):
        return None
    allowed = {"scripts/highlight_acceptance.py", "scripts/highlight_process.py"}
    if not isinstance(locations, list) or not 1 <= len(locations) <= 16:
        return None
    for location in locations:
        if (not isinstance(location, dict) or set(location) != {"script", "line"} or
                not isinstance(location["script"], str) or location["script"] not in allowed or
                type(location["line"]) is not int or not 1 <= location["line"] <= 1000000):
            return None
    return locations


def public_cancel_host_command(bash: Path | None) -> list[str]:
    """Use the caller's native Bash without Windows executable re-resolution."""
    if bash is None:
        if os.name == "nt":
            raise ValueError("Windows host builds require the workflow's explicit --bash launcher")
        launcher = shutil.which("bash")
    elif not bash.is_absolute():
        raise ValueError("an explicit Bash launcher must be an absolute executable path")
    else:
        launcher = shutil.which(str(bash))
    if launcher is None:
        raise ValueError("the host build's Bash launcher is unavailable")
    return [launcher, "--noprofile", "--norc", "-c",
            '. scripts/with_sts_o1_cjpm.sh; cd tests/fixtures/projects/highlight_host; '
            'cjpm build --jobs 1 --target-dir "$CJDOC_HIGHLIGHT_BUILD"']


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--identity", type=Path, required=True)
    parser.add_argument("--platform", choices=sorted(PLATFORMS.values()), required=True)
    parser.add_argument("--work-root", type=Path, required=True)
    parser.add_argument("--evidence-root", type=Path, required=True)
    parser.add_argument("--bash", type=Path,
                        help="absolute native Bash executable (required on Windows; pass the workflow shell)")
    args = parser.parse_args()
    repo, binary = args.repo.resolve(), args.binary.resolve()
    if os.name == "nt" and not binary.is_file():
        binary = Path(str(binary) + ".exe")
    evidence = private_directory(args.evidence_root, repo)
    identity = {"schemaVersion": "cjdoc.highlight-ci/1", "status": "running",
                "platform": args.platform, "steps": []}
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")


    def run(name: str, command: list[str], *, cwd: Path = repo, timeout: int = 1200) -> str:
        started = time.monotonic()
        log = evidence / (name + ".json")
        raw = args.work_root / (name + ".raw.log")
        raw_stderr = args.work_root / (name + ".stderr.log")
        step = {"name": name, "exitCode": None, "status": "running", "timeoutSeconds": timeout}
        bounded = [sys.executable, str(repo / "scripts/run_with_timeout.py"),
                   str(timeout), "--", *command]
        try:
            with raw.open("wb") as stream, raw_stderr.open("wb") as errors:
                result = subprocess.run(bounded, cwd=cwd, env=env, stdout=stream,
                                        stderr=errors, check=False)
            step["exitCode"] = result.returncode
            if result.returncode == 124:
                raise subprocess.TimeoutExpired(command, timeout)
            if result.returncode:
                raise subprocess.CalledProcessError(result.returncode, command)
            step["status"] = "passed"
            return raw.read_text(encoding="utf-8", errors="replace")
        except Exception as error:
            step.update(failure_facts(error))
            step["status"] = "failed"
            if name == "worker-acceptance":
                locations = load_traceback_locations(args.work_root / "acceptance/failure-locations.json")
                if locations is not None:
                    step["tracebackLocations"] = locations
            raise
        finally:
            # Raw stdout/stderr remains private; public artifacts contain fixed facts only.
            step["wallMs"] = round((time.monotonic() - started) * 1000)
            identity["steps"].append(step)
            log.write_text(json.dumps(step, indent=2) + "\n", encoding="utf-8")

    try:
        work = private_directory(args.work_root, repo)
        require_disk_work_root(work)
        if PLATFORMS.get((sys.platform, platform.machine().lower())) != args.platform:
            raise ValueError("runner platform does not match its required matrix entry")
        if not os.environ.get("CJDOC_STDX_DIGEST") or not os.environ.get("CJDOC_STDX_PATH"):
            raise ValueError("authenticate the static stdx sidecar before optional CI")
        node, npm = shutil.which("node"), shutil.which("npm")
        if not node or not npm:
            raise ValueError("the required optional CI Node/npm installation is missing")
        node_version = run("node-version", [node, "--version"]).strip()
        run("build-identity", [sys.executable, "scripts/ci_stage.py", "verify-identity",
                              "--manifest", str(args.identity.resolve()), "--repo", str(repo),
                              "--main-binary", str(binary)])
        manifest = json.loads(args.identity.read_text(encoding="utf-8"))
        head = run("checkout-head", ["git", "-C", str(repo), "rev-parse", "HEAD"]).strip()
        if head != manifest["checkoutCommit"] or (os.environ.get("GITHUB_SHA") and head != os.environ["GITHUB_SHA"]):
            raise ValueError("optional worker source must be the exact current CI HEAD")
        if manifest["toolchain"]["stdxDigest"] != os.environ["CJDOC_STDX_DIGEST"]:
            raise ValueError("optional worker sidecar differs from the authenticated main build")
        identity.update({key: manifest[key] for key in ["checkoutCommit", "checkoutTree", "toolchain"]})
        identity["mainBinary"] = {"sha256": sha256(binary), "bytes": binary.stat().st_size}
        identity["node"] = node_version
        identity["nodeSha256"] = sha256(Path(node))
        identity["runId"] = os.environ.get("GITHUB_RUN_ID", "")
        identity["runAttempt"] = os.environ.get("GITHUB_RUN_ATTEMPT", "")
        identity["highlightJs"] = HIGHLIGHT_VERSION
        archive = work / "source.tar"
        run("tracked-source", ["git", "-C", str(repo), "archive", "--format=tar",
                               "--output", str(archive), manifest["checkoutCommit"]])
        source = work / "source"
        source.mkdir(mode=0o700)
        with tarfile.open(archive) as bundle:
            bundle.extractall(source, filter="data")
        identity["sourceArchiveSha256"] = sha256(archive)

        require_versions(source, node_version)
        private_binary = work / binary.name
        shutil.copy2(binary, private_binary)
        env.update({"GITHUB_WORKSPACE": str(source), "TMPDIR": str(work), "TMP": str(work),
                    "TEMP": str(work), "RUNNER_TEMP": str(work),
                    "CANGJIE_STDX_PATH": os.environ["CJDOC_STDX_PATH"],
                    "CJDOC_HIGHLIGHT_BUILD": str(work / "host-build"),
                    "CJDOC_STS_INVOCATION_LOG": str(work / "sts-invocations.jsonl")})
        run("public-cancel-host", public_cancel_host_command(args.bash), cwd=source)
        probe = work / "host-build/release/bin" / ("main.exe" if os.name == "nt" else "main")
        if not probe.is_file():
            raise ValueError("public cancellation host was not built")
        for key in list(env):
            if key.lower() == "npm_config_cache":
                del env[key]
        env["npm_config_cache"] = str(work / "npm-cache")
        npm_command = [npm, "ci", "--ignore-scripts", "--no-audit", "--no-fund"]
        run("adapter-install", npm_command, cwd=source / "tools/highlight", timeout=300)
        run("adapter-contracts", [node, "--test"], cwd=source / "tools/highlight", timeout=120)
        run("adapter-python-contracts", [sys.executable, "-m", "unittest",
            "scripts.test_highlight_adapter", "-v"], cwd=source, timeout=120)
        result = work / "acceptance"
        run("worker-acceptance", [sys.executable, "scripts/highlight_acceptance.py", "--binary",
            str(private_binary), "--node", node, "--api-probe", str(probe), "--workdir", str(result)],
            cwd=source, timeout=600)
        shutil.copyfile(result / "report.json", evidence / "report.json")
        if sha256(binary) != identity["mainBinary"]["sha256"]:
            raise ValueError("optional CI modified the original main binary")
        identity["reportSha256"] = sha256(evidence / "report.json")
        identity["publicCancelHostSha256"] = sha256(probe)
        identity["status"] = "passed"
        return 0
    except Exception as error:
        identity["status"] = "failed"
        identity.update(failure_facts(error))
        print("optional highlight CI failed; inspect its structured evidence", file=sys.stderr)
        return 1
    finally:
        (evidence / "identity.json").write_text(json.dumps(identity, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    try:
        result = main()
    except Exception:
        print("optional highlight CI setup failed", file=sys.stderr)
        result = 1
    raise SystemExit(result)
