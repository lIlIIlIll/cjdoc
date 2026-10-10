#!/usr/bin/env python3
"""Write the per-platform `cjdoc.release-candidate/1` receipt.

One release candidate job builds, runs the platform acceptance gates and writes
this receipt before packaging. `publish` and `package_release.py` then prove that
the archive they ship was produced from exactly this receipt: same tag, commit,
tree, toolchain archives and executable digest.

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

RECEIPT_SCHEMA = "cjdoc.release-candidate/1"
GATE_SCHEMA = "cjdoc.release-gate/3"
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
    wrapper = repo / "scripts/with_sts_o1_cjpm.sh"
    composed = {"compileOptions": compile_options,
                "wrapperInputs": ["cjpm.toml:override-compile-option",
                                  f"scripts/with_sts_o1_cjpm.sh:{sha256_file(wrapper)}"]}
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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--platform", required=True,
                        choices=("linux-x64", "windows-x64", "macos-arm64"))
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--sdk-archive-sha256", required=True)
    parser.add_argument("--stdx-archive-sha256", required=True)
    parser.add_argument("--sdk-version", required=True)
    parser.add_argument("--stdx-version", required=True)
    parser.add_argument("--gate", type=Path, action="append", default=[])
    parser.add_argument("--compile-option", action="append", default=["-O1"])
    parser.add_argument("--release-gate-receipt", type=Path,
                        help="upgraded cjdoc.release-gate/3 receipt for the Linux job")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
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
    version = run([str(binary), "--version"]).splitlines()[0]
    gates = gate_digests(list(args.gate))
    if args.release_gate_receipt is not None:
        receipt = json.loads(args.release_gate_receipt.read_text(encoding="utf-8"))
        if receipt.get("schemaVersion") != GATE_SCHEMA:
            parser.error("--release-gate-receipt is not cjdoc.release-gate/3")
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
                  "buildConfigurationSha256": build_configuration_digest(args.repo, list(args.compile_option))},
        "binary": {"path": binary_relative,
                   "sha256": sha256_file(binary), "size": binary.stat().st_size,
                   "versionOutput": version},
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
