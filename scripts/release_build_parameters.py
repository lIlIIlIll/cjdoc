#!/usr/bin/env python3
"""Assert the release build parameters are uniform across platforms (CI-08.3).

#82 requires that if a platform needs different package build parameters, it must
produce its **own** candidate and be accepted against it, rather than reusing
another candidate's test conclusions. Today all three platforms share one build
command and one override, so the requirement holds by construction — but only an
absence enforced it. This check makes the determination explicit and fails loudly
the moment a platform diverges without the matching work.

Both facts are observed rather than modelled:

* the build command is **parsed out of the release workflow's candidate job** and
  must be a single, plain `cjpm` statement — a compound shell line or an
  interpolated argument would let the effective command differ per platform while
  still looking uniform;
* the effective compile option is read from the **receipt the wrapper's own patch
  step writes** while the wrapper runs. That means the value comes from the real
  call path: the wrapper is executed, it invokes `scripts/apply_sts_override.py`,
  and the check only reads the result. Searching the wrapper's text, restating a
  constant, or re-running the patcher with arguments reconstructed here would all
  vouch for something the release does not actually do.

Executing the wrapper requires a POSIX shell. The release candidate job runs on
`ubuntu-22.04`, so this is the platform the check is written for; where no shell is
available it refuses instead of passing by default.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True

PLATFORMS = ("linux-x64", "windows-x64", "macos-arm64")
WORKFLOW = Path(".github/workflows/release.yml")
WRAPPER = Path("scripts/with_sts_o1_cjpm.sh")
PATCHER = Path("scripts/apply_sts_override.py")
OVERRIDE_MODULE = Path("scripts/sts_compile_override.py")
RECEIPT_NAME = "cjdoc-sts-override-receipt.json"
CANDIDATE_JOB = "\n  release-candidate:\n"
PUBLISH_JOB = "\n  publish:\n"
# The option the pinned toolchain needs, and therefore the one the release requires.
REQUIRED_OPTION = "-O1"
# Shell tokens that turn one visible `cjpm` statement into several, or into a
# conditional one. A uniform command cannot contain any of them.
SHELL_CONTROL = {"&&", "||", ";", "|", "&", ">", ">>", "<", "2>", "2>&1"}
PROBE_CJPM = """#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  -v|--version) exit 0 ;;
esac
"${CJDOC_PYTHON:-python3}" - "${RUNNER_TEMP}/%s" <<'PY'
import json, sys
from pathlib import Path
receipt = Path(sys.argv[1])
if not receipt.is_file():
    print("CJDOC_RECEIPT_MISSING")
else:
    print("CJDOC_RECEIPT=" + json.dumps(json.loads(receipt.read_text(encoding="utf-8"))))
PY
""" % RECEIPT_NAME


class ParameterError(SystemExit):
    """A divergence that must stop the release (CI-08.3)."""

    def __init__(self, platform: str, detail: str) -> None:
        super().__init__(
            f"release build parameters: {platform} {detail}; a platform with distinct "
            "build parameters must produce its own candidate and run its own acceptance "
            "against that candidate (CI-08.3)")


def discover_build_command(workflow: Path) -> list[str]:
    """The single `cjpm` statement the candidate job runs, or a refusal."""
    text = workflow.read_text(encoding="utf-8")
    if CANDIDATE_JOB not in text or PUBLISH_JOB not in text:
        raise SystemExit(f"release build parameters: {workflow} has no expected job layout")
    candidate = text.split(CANDIDATE_JOB, 1)[1].split(PUBLISH_JOB, 1)[0]
    # Join shell continuations first: a multi-line invocation is still one statement,
    # and splitting a dangling backslash raises in shlex.
    joined = candidate.replace("\\\n", " ")
    statements = [line.strip() for line in joined.splitlines()
                  if line.strip() and not line.strip().startswith("#")]
    calls = [line for line in statements if shlex.split(line)[0] == "cjpm"]
    if len(calls) != 1:
        raise SystemExit(
            f"release build parameters: {workflow} candidate job has {len(calls)} cjpm "
            "statements, so the per-platform build parameters are no longer uniform and "
            "this check cannot vouch for them (CI-08.3)")
    command = shlex.split(calls[0])
    if command[:2] != ["cjpm", "build"]:
        raise SystemExit(
            f"release build parameters: the candidate job's build statement is "
            f"{calls[0]!r}, not a plain `cjpm build` (CI-08.3)")
    # `&& cjpm build --jobs 4` splits into ordinary tokens, so control operators
    # must be rejected explicitly: bash would run both builds and package the latter
    # while this check still reported one uniform command.
    found = sorted({token for token in command if token in SHELL_CONTROL})
    if found:
        raise SystemExit(
            f"release build parameters: the candidate job's build statement contains "
            f"{found[0]!r}, so it may run more than one build; make the single build "
            "explicit and give any platform that needs different parameters its own "
            "candidate (CI-08.3)")
    expansions = [token for token in command if "$" in token or "`" in token]
    if expansions:
        raise SystemExit(
            f"release build parameters: the candidate job builds with an interpolated "
            f"argument {expansions[0]!r}, so the effective parameters can differ per "
            "platform; make each platform's build explicit and give it its own "
            "candidate (CI-08.3)")
    return command


def observed_receipt(repo: Path) -> dict:
    """Run the wrapper and return the receipt its patch step produced.

    The wrapper is the artefact under test, so it is executed rather than described.
    A fake `cjpm` on PATH stands in for the real one and prints the receipt, which
    is written before the build would start.
    """
    if shutil.which("bash") is None and shutil.which("sh") is None:
        raise SystemExit(
            "release build parameters: no POSIX shell is available, so the wrapper's "
            "override cannot be observed; this check is written for the Linux release "
            "candidate job (CI-08.3)")
    manifest = (repo / "cjpm.toml").read_bytes()
    with tempfile.TemporaryDirectory(prefix="cjdoc-build-params-") as temporary:
        staging = Path(temporary)
        (staging / "cjpm.toml").write_bytes(manifest)
        runner_temp = staging / "runner-temp"
        probe_bin = runner_temp / "probe-bin"
        probe_bin.mkdir(parents=True)
        for name, body in (("cjpm", PROBE_CJPM), ("cjc", "#!/usr/bin/env bash\nexit 0\n")):
            binary = probe_bin / name
            binary.write_text(body, encoding="utf-8")
            binary.chmod(0o755)
        environment = dict(os.environ)
        environment.update({
            "GITHUB_WORKSPACE": str(staging),
            "RUNNER_TEMP": str(runner_temp),
            "CJDOC_STS_OVERRIDE_MODULE": str(repo / "scripts"),
            "PATH": f"{probe_bin}{os.pathsep}{environment.get('PATH', '')}",
        })
        environment.pop("CJDOC_PYTHON", None)
        command = (f". {shlex.quote(str(repo / WRAPPER))} >/dev/null 2>&1 && cjpm build")
        try:
            result = subprocess.run(["bash", "-c", command], cwd=staging, env=environment,
                                    capture_output=True, text=True, timeout=900)
        except (OSError, subprocess.SubprocessError) as error:
            raise SystemExit(f"release build parameters: could not run {WRAPPER}: {error}")
        if result.returncode != 0:
            raise SystemExit(
                f"release build parameters: {WRAPPER} exited {result.returncode} during the "
                f"probe: {result.stderr.strip() or result.stdout.strip()}")
        if "CJDOC_RECEIPT_MISSING" in result.stdout:
            raise SystemExit(
                f"release build parameters: {WRAPPER} applied no override during the probe, "
                "so the release would build with the committed default (CI-08.3)")
        found = [line for line in result.stdout.splitlines()
                 if line.startswith("CJDOC_RECEIPT=")]
        if len(found) != 1:
            raise SystemExit(
                f"release build parameters: could not read the override receipt from "
                f"{WRAPPER}: {result.stdout.strip() or result.stderr.strip()}")
        receipt = json.loads(found[0].split("=", 1)[1])
        # The rewrite must leave the tree it touched as it found it.
        if (staging / "cjpm.toml").read_bytes() != manifest:
            raise SystemExit(
                "release build parameters: the wrapper did not restore the manifest it "
                "patched, so the build parameters cannot be trusted")
        return receipt


def check(repo: Path, platform: str, workflow: Path) -> dict[str, object]:
    if platform not in PLATFORMS:
        raise SystemExit(f"release build parameters: unknown platform {platform!r}")
    for required in (WRAPPER, PATCHER, OVERRIDE_MODULE):
        if not (repo / required).is_file():
            raise SystemExit(f"release build parameters: missing {required}")
    command = discover_build_command(workflow)
    receipt = observed_receipt(repo)
    option = receipt.get("option")
    if receipt.get("schemaVersion") != "cjdoc.sts-override-receipt/1" or not option:
        raise SystemExit(
            f"release build parameters: unexpected override receipt {receipt!r} (CI-08.3)")
    if option != REQUIRED_OPTION:
        raise ParameterError(
            platform,
            f"the wrapper's patch step applied {option!r}, not the required "
            f"{REQUIRED_OPTION!r}")
    return {
        "schemaVersion": "cjdoc.release-build-parameters/1",
        "platform": platform,
        "command": command,
        "effectiveCompileOption": option,
        "appliedTo": receipt.get("applied"),
        "wrapper": WRAPPER.as_posix(),
        "wrapperSha256": hashlib.sha256((repo / WRAPPER).read_bytes()).hexdigest(),
        "uniformAcross": list(PLATFORMS),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--platform", required=True, choices=PLATFORMS)
    parser.add_argument("--workflow", type=Path)
    args = parser.parse_args()
    repo = args.repo.resolve()
    workflow = (args.workflow.resolve() if args.workflow else repo / WORKFLOW)
    print(json.dumps(check(repo, args.platform, workflow), ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
