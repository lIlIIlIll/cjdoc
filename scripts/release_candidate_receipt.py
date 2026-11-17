#!/usr/bin/env python3
"""Write the per-platform `cjdoc.release-candidate/2` receipt.

One release candidate job builds, runs the platform acceptance gates and writes
this receipt before packaging. `publish` and `package_release.py` then prove that
the archive they ship was produced from exactly this receipt: same tag, commit,
tree, toolchain archives, and the bytes of both shipped executables — the CLI and
the CHIR worker it discovers beside itself.

The worker is not optional evidence: `--worker-binary` must be the staged sibling
of the accepted CLI, its digest/size must equal the sealed build manifest's
`workerBinary`, and it must be the artifact the recorded `cjdoc_chir_worker` build
produced. A same-version worker from another tree therefore cannot be claimed as
accepted. The worker's own `--version` and `--protocol-version` output are recorded
here so the packaged pair can be re-executed and compared.

`worktreeSha256`, `stdxDigest` and `toolchainFingerprint` come from the real
wrapper output, never from a cache marker's self-description.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))

from safe_output_root import safe_output_file
from worktree_identity import exact_worktree_identity
from verify_build_invocations import read_since, verify as verify_build_invocations
from sts_compile_override import KNOWN_PACKAGES
from release_package_contracts import worker_executable

RECEIPT_SCHEMA = "cjdoc.release-candidate/2"
GATE_SCHEMA = "cjdoc.release-gate/4"
BUILD_MANIFEST_SCHEMA = "cjdoc.ci-build-manifest/1"
WORKER_PACKAGE = "cjdoc_chir_worker"
REQUIRED_COMPILE_OPTIONS = ["-O2", "--fno-chir-function-inlining"]
SHA256 = re.compile(r"^[0-9a-f]{64}$")
COMMIT = re.compile(r"^[0-9a-f]{40}$")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def canonical_json(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True,
                      separators=(",", ":"), allow_nan=False).encode("utf-8")


def run(command: list[str], *, check: bool = True) -> str:
    try:
        completed = subprocess.run(command, text=True, capture_output=True)
    except OSError as error:
        # Missing tool, wrong executable format (WinError 193) and permission
        # errors are all reported conditions, never a bare traceback.
        raise SystemExit(f"release receipt: command failed: {command[0]} could not run: {error}")
    if check and completed.returncode != 0:
        raise SystemExit(f"release receipt: command failed: {' '.join(command)}: {completed.stderr.strip()}")
    return (completed.stdout + completed.stderr).strip()


def tool_version(command: str) -> str:
    first = run([command, "-v"]).splitlines()
    return first[0].strip() if first else ""


def build_configuration_digest(repo: Path, compile_options: list[str]) -> str:
    wrapper = repo / "scripts/with_sts_cjpm.sh"
    composed = {"compileOptions": compile_options,
                "wrapperInputs": ["cjpm.toml:override-compile-option",
                                  f"scripts/with_sts_cjpm.sh:{sha256_file(wrapper)}",
                                  f"scripts/sts_compile_override.py:{sha256_file(repo / 'scripts/sts_compile_override.py')}"]}
    return hashlib.sha256(canonical_json(composed)).hexdigest()


def collect_platform() -> dict[str, object]:
    import platform as machine

    system = machine.system()
    identifier = {"Linux": "linux-x64", "Darwin": "macos-arm64",
                  "Windows": "windows-x64"}.get(system, system.lower())
    compiler_target = run(["cjc", "-v"]).split("Target:")
    target = compiler_target[1].strip().splitlines()[0] if len(compiler_target) > 1 else ""
    return {"id": identifier, "os": system, "architecture": machine.machine(),
            "compilerTarget": target}


def gate_digests(paths: list[Path]) -> dict[str, str]:
    gates: dict[str, str] = {}
    for path in paths:
        if not path.is_file():
            raise SystemExit(f"release receipt: gate evidence is missing: {path}")
        gates[path.name] = sha256_file(path)
    return gates


def relative_to_repo(repo: Path, path: Path, description: str) -> str:
    try:
        return path.resolve().relative_to(repo.resolve()).as_posix()
    except ValueError:
        raise SystemExit(
            f"release receipt: {description} must live inside the repository: {path}")


def verify_sealed_build(repo: Path, manifest_path: Path, commit: str, tree: str,
                        main: Path, worker: Path) -> dict[str, object]:
    """Require both executables to be the ones this exact build sealed.

    `scripts/check.sh build` writes the manifest from the two artefacts it just
    produced in the same job, so its identities bind the packaged bytes to this
    source tree, this SDK and this run. A worker built elsewhere — even a
    same-version one — cannot match them.
    """
    try:
        manifest_bytes = manifest_path.read_bytes()
        manifest = json.loads(manifest_bytes.decode("utf-8"))
    except OSError as error:
        raise SystemExit(f"release receipt: sealed build manifest is missing: {error}")
    except json.JSONDecodeError as error:
        raise SystemExit(f"release receipt: sealed build manifest is invalid: {error}")
    if not isinstance(manifest, dict) or manifest.get("schemaVersion") != BUILD_MANIFEST_SCHEMA:
        raise SystemExit("release receipt: sealed build manifest has an unexpected schema")
    if manifest.get("checkoutCommit") != commit or manifest.get("checkoutTree") != tree:
        raise SystemExit("release receipt: sealed build manifest is for a different source tree")
    for platform_key, expected in (("runId", os.environ.get("GITHUB_RUN_ID", "")),
                                   ("runAttempt", int(os.environ.get("GITHUB_RUN_ATTEMPT", "0") or 0))):
        recorded = manifest.get(platform_key)
        if recorded not in ("", None) and recorded != expected:
            raise SystemExit(
                f"release receipt: sealed build manifest was produced by a different run "
                f"({platform_key} {recorded!r} != {expected!r})")
    sealed: dict[str, object] = {}
    for key, path in (("mainBinary", main), ("workerBinary", worker)):
        recorded = manifest.get(key)
        if not isinstance(recorded, dict):
            raise SystemExit(f"release receipt: sealed build manifest omits {key}")
        if recorded.get("sha256") != sha256_file(path) or recorded.get("size") != path.stat().st_size:
            raise SystemExit(
                f"release receipt: {key} was not the artefact this build sealed")
        sealed[key] = {"path": str(recorded.get("path") or ""),
                       "sha256": str(recorded.get("sha256")), "size": int(recorded.get("size"))}
    return {"path": relative_to_repo(repo, manifest_path, "sealed build manifest"),
            "sha256": hashlib.sha256(manifest_bytes).hexdigest(),
            "mainBinary": sealed["mainBinary"], "workerBinary": sealed["workerBinary"]}


def worker_metadata(worker: Path) -> tuple[str, str]:
    """Return the worker's own product and protocol identity output."""
    return (run([str(worker), "--version"]).splitlines()[0].strip(),
            run([str(worker), "--protocol-version"]).splitlines()[0].strip())


def worker_record(repo: Path, worker: Path) -> dict[str, object]:
    version, protocol = worker_metadata(worker)
    return {"path": relative_to_repo(repo, worker, "release candidate worker"),
            "sha256": sha256_file(worker), "size": worker.stat().st_size,
            "versionOutput": version, "protocolVersion": protocol}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--platform", required=True,
                        choices=("linux-x64", "windows-x64", "macos-arm64"))
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--worker-binary", type=Path, required=True,
                        help="the CHIR worker staged beside the accepted CLI")
    parser.add_argument("--build-manifest", type=Path, required=True,
                        help="the sealed build manifest that recorded both executables")
    parser.add_argument("--sdk-archive-sha256", required=True)
    parser.add_argument("--stdx-archive-sha256", required=True)
    parser.add_argument("--sdk-version", required=True)
    parser.add_argument("--stdx-version", required=True)
    parser.add_argument("--gate", type=Path, action="append", default=[])
    parser.add_argument("--compile-option", action="append",
                        help="explicit product flag tokens; must exactly match the frozen policy")
    parser.add_argument("--invocation-log", type=Path,
                        help="actual STS invocation log; defaults to CJDOC_STS_INVOCATION_LOG or RUNNER_TEMP")
    parser.add_argument("--release-gate-receipt", type=Path,
                        help="upgraded cjdoc.release-gate/4 receipt for the Linux job")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.compile_option = list(REQUIRED_COMPILE_OPTIONS) if args.compile_option is None else args.compile_option
    if args.compile_option != REQUIRED_COMPILE_OPTIONS:
        parser.error("product flags must be exactly " + " ".join(REQUIRED_COMPILE_OPTIONS))
    if args.invocation_log is None:
        configured = os.environ.get("CJDOC_STS_INVOCATION_LOG")
        runner_temp = os.environ.get("RUNNER_TEMP")
        args.invocation_log = Path(configured) if configured else (
            Path(runner_temp) / "cjdoc-sts-invocations.jsonl" if runner_temp else None)
    if args.invocation_log is None:
        parser.error("an actual STS invocation log is required (--invocation-log)")
    for name in ("sdk_archive_sha256", "stdx_archive_sha256"):
        if not SHA256.fullmatch(getattr(args, name)):
            parser.error(f"--{name.replace('_', '-')} must be lowercase 64-hex")

    identity = exact_worktree_identity(args.repo)
    commit, tree = str(identity["headCommit"]), str(identity["tree"])
    if not COMMIT.fullmatch(commit):
        parser.error("repository HEAD is not a full commit id")
    binary = args.binary.resolve()
    if not binary.is_file():
        parser.error(f"release candidate binary is missing: {binary}")
    try:
        binary_relative = binary.relative_to(args.repo.resolve()).as_posix()
    except ValueError:
        parser.error(f"release candidate binary must live inside the repository: {binary}")
    worker = args.worker_binary.resolve()
    if not worker.is_file():
        parser.error(f"release candidate worker is missing: {worker}")
    # The installed CLI resolves its companion from its own directory, so the
    # packaged names must be siblings before anything else is claimed.
    expected_worker_name = worker_executable(str(args.platform).startswith("windows-"))
    if worker.name != expected_worker_name or worker.parent != binary.parent:
        parser.error(
            f"release candidate worker must be {expected_worker_name} beside the CLI, "
            f"not {worker}")
    if WORKER_PACKAGE not in KNOWN_PACKAGES:
        parser.error("the CHIR worker package is not an accepted build package")
    records = read_since(args.invocation_log, 0)
    invocation_summary = verify_build_invocations(
        records, " ".join(REQUIRED_COMPILE_OPTIONS), binary, ["build", "--jobs", "1"])
    # The worker must be the artefact the recorded worker build produced. Running
    # the same verification against the same log binds the second binary instead
    # of trusting whatever worker happens to sit beside the CLI.
    worker_summary = verify_build_invocations(
        records, " ".join(REQUIRED_COMPILE_OPTIONS), worker, ["build", "--jobs", "1"],
        WORKER_PACKAGE)
    policy_digest = sha256_file(args.repo / "scripts/sts_compile_override.py")
    wrapper_digest = sha256_file(args.repo / "scripts/with_sts_cjpm.sh")
    for record in records:
        if record.get("argv", [])[:1] == ["build"] and record.get("package") in KNOWN_PACKAGES:
            if record.get("policySha256") != policy_digest or record.get("wrapperSha256") != wrapper_digest:
                parser.error("build invocation policy/wrapper source does not match the candidate")
    sealed = verify_sealed_build(args.repo, args.build_manifest, commit, tree, binary, worker)
    version = run([str(binary), "--version"]).splitlines()[0]
    worker_entry = worker_record(args.repo, worker)
    gates = gate_digests(list(args.gate))
    if args.release_gate_receipt is not None:
        receipt = json.loads(args.release_gate_receipt.read_text(encoding="utf-8"))
        if receipt.get("schemaVersion") != GATE_SCHEMA:
            parser.error("--release-gate-receipt is not cjdoc.release-gate/4")
        gates["release-gate"] = sha256_file(args.release_gate_receipt)
    document = {
        "schemaVersion": RECEIPT_SCHEMA,
        "source": {"tag": args.tag, "releaseVersion": args.tag.lstrip("v"),
                   "commit": commit, "tree": tree, "dirty": bool(identity["dirty"]),
                   "worktreeSha256": str(identity["worktreeSha256"])},
        "platform": collect_platform(),
        "toolchain": {
            "sdkVersion": args.sdk_version,
            "sdkArchiveSha256": args.sdk_archive_sha256,
            "stdxVersion": args.stdx_version,
            "stdxArchiveSha256": args.stdx_archive_sha256,
            "compilerVersion": tool_version("cjc"),
            "cjpmVersion": tool_version("cjpm"),
            "stdxDigest": os.environ.get("CJDOC_STDX_DIGEST", ""),
            "toolchainFingerprint": os.environ.get("CJDOC_TOOLCHAIN_FINGERPRINT", ""),
        },
        "build": {"command": ["cjpm", "build", "--jobs", "1"],
                  "effectiveCompileOptions": list(args.compile_option),
                  "invocationLogSha256": sha256_file(args.invocation_log),
                  "invocationSummary": invocation_summary,
                  "workerInvocationSummary": worker_summary,
                  "buildConfigurationSha256": build_configuration_digest(args.repo, list(args.compile_option))},
        "binary": {"path": binary_relative,
                   "sha256": sha256_file(binary), "size": binary.stat().st_size,
                   "versionOutput": version},
        "worker": worker_entry,
        "buildManifest": sealed,
        "execution": {"runId": os.environ.get("GITHUB_RUN_ID", ""),
                      "runAttempt": int(os.environ.get("GITHUB_RUN_ATTEMPT", "0") or 0),
                      "job": os.environ.get("GITHUB_JOB", "")},
        "gates": gates,
    }
    target = safe_output_file(args.output, description="release candidate receipt")
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
                      encoding="utf-8", newline="\n")
    print(f"release candidate receipt written: {target}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
