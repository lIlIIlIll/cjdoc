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
# Shell metacharacters that turn one visible `cjpm` statement into several, or into
# a conditional one. A uniform command cannot contain any of them, and they are
# detected *inside* tokens too: `1&&cjpm` is one shlex token but bash still treats
# the adjacent `&&` as a control operator.
SHELL_CONTROL = "&|;<>`()"
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
    """The single `cjpm build` the candidate job runs, or a refusal.

    The search is over every `cjpm build` token in the candidate job, not over the
    statements whose first word is `cjpm`: a nested `if ...; then cjpm build --jobs 4;
    fi` on its own line starts with `if`, yet bash would run it and the workflow could
    package the binary it produces.
    """
    text = workflow.read_text(encoding="utf-8")
    if CANDIDATE_JOB not in text or PUBLISH_JOB not in text:
        raise SystemExit(f"release build parameters: {workflow} has no expected job layout")
    candidate = text.split(CANDIDATE_JOB, 1)[1].split(PUBLISH_JOB, 1)[0]
    # Join shell continuations first: a multi-line invocation is still one statement,
    # and a dangling backslash also makes shlex raise.
    executable = candidate.replace("\\\n", " ")
    lines = [line.strip() for line in executable.splitlines()
             if line.strip() and not line.strip().startswith("#")]

    builds = [line for line in lines if "cjpm build" in line]
    if not builds:
        raise SystemExit(
            f"release build parameters: {workflow} candidate job never runs `cjpm build`, "
            "so its build parameters cannot be established (CI-08.3)")
    if len(builds) != 1:
        raise SystemExit(
            f"release build parameters: {workflow} candidate job runs `cjpm build` on "
            f"{len(builds)} lines, so the per-platform build parameters are no longer "
            "uniform and this check cannot vouch for them (CI-08.3)")
    statement = builds[0]
    # `&&`, `;` or `|` would let one line run several builds; a leading `if`/`then`/
    # `case` would run it conditionally, i.e. on some platforms and not others.
    command = shlex.split(statement)
    if command[0] != "cjpm":
        raise SystemExit(
            f"release build parameters: the candidate job's build line is {statement!r}, "
            "which is not a bare `cjpm build`; a build nested in a shell construct can "
            "run on some platforms only (CI-08.3)")
    if command[:2] != ["cjpm", "build"]:
        raise SystemExit(
            f"release build parameters: the candidate job's build statement is "
            f"{statement!r}, not a plain `cjpm build` (CI-08.3)")
    # Operators are searched for inside tokens as well: `cjpm build --jobs 1&&cjpm
    # build --jobs 4` is one line whose tokens are ordinary, yet bash runs two builds
    # and packages the latter while this check still saw one command.
    found = []
    index = 0
    while index < len(statement):
        character = statement[index]
        if character in "'\"":
            closing = statement.find(character, index + 1)
            index = len(statement) if closing < 0 else closing + 1
            continue
        if character in SHELL_CONTROL:
            found.append(character)
        index += 1
    if found:
        raise SystemExit(
            f"release build parameters: the candidate job's build statement contains the "
            f"unquoted shell metacharacter {found[0]!r}, so it may run more than one build "
            "or build something other than one uniform command; make the single build "
            "explicit and give any platform that needs different parameters its own "
            "candidate (CI-08.3)")
    expansions = [token for token in command if "$" in token or "`" in token]
    if expansions:
        raise SystemExit(
            f"release build parameters: the candidate job builds with an interpolated "
            f"argument {expansions[0]!r}, so the effective parameters can differ per "
            f"platform; make each platform's build explicit and give it its own "
            "candidate (CI-08.3)")
    return command


def usable_shell() -> str | None:
    """A POSIX shell that can actually run a command, or None.

    `shutil.which` is not enough: on Windows `bash` resolves to the WSL launcher,
    which exists but refuses every command when no distribution is installed.
    """
    for name in ("bash", "sh"):
        candidate = shutil.which(name)
        if candidate is None:
            continue
        try:
            probe = subprocess.run([candidate, "-c", "exit 0"], capture_output=True,
                                   text=True, timeout=60)
        except (OSError, subprocess.SubprocessError):
            continue
        if probe.returncode == 0:
            return candidate
    return None


def shell_is_usable() -> bool:
    """Whether the wrapper's override can be observed on this machine."""
    return usable_shell() is not None


def observed_receipt(repo: Path) -> dict:
    """Run the wrapper and return the receipt its patch step produced.

    The wrapper is the artefact under test, so it is executed rather than described.
    A fake `cjpm` on PATH stands in for the real one and prints the receipt, which
    is written before the build would start.
    """
    shell = usable_shell()
    if shell is None:
        raise SystemExit(
            "release build parameters: no usable POSIX shell is available, so the "
            "wrapper's override cannot be observed; this check is written for the Linux "
            "release candidate job (CI-08.3)")
    manifest = (repo / "cjpm.toml").read_bytes()
    with tempfile.TemporaryDirectory(prefix="cjdoc-build-params-") as temporary:
        # Resolve symlinks: the wrapper decides whether to patch by comparing `$PWD`
        # with `$GITHUB_WORKSPACE`, and on macOS `getcwd()` reports the physical path
        # (`/private/var/...`) while `tempfile` hands out the aliased one (`/var/...`).
        # Left unresolved the two never match, the wrapper passes straight through to
        # the real `cjpm`, and no override is applied — which is how this failed on the
        # macOS leg while Linux passed.
        staging = Path(temporary).resolve()
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
            # Pin both the wrapper's patcher call and the probe `cjpm` to the
            # interpreter running this check: it is guaranteed to exist, while a
            # bare `python`/`python3` may not on every runner.
            "CJDOC_PYTHON": sys.executable,
            "PATH": f"{probe_bin}{os.pathsep}{environment.get('PATH', '')}",
        })
        # Keep the wrapper's output: without it a failure here is indistinguishable
        # from a genuinely missing override, which is exactly how the macOS leg
        # failed once already.
        command = (f". {shlex.quote(str(repo / WRAPPER))} && cjpm build")
        try:
            result = subprocess.run([shell, "-c", command], cwd=staging, env=environment,
                                    capture_output=True, text=True, timeout=900)
        except (OSError, subprocess.SubprocessError) as error:
            raise SystemExit(f"release build parameters: could not run {WRAPPER}: {error}")
        if result.returncode != 0:
            raise SystemExit(
                f"release build parameters: {WRAPPER} exited {result.returncode} during the "
                f"probe: {(result.stderr or result.stdout).strip()[-2000:]}")
        if "CJDOC_RECEIPT_MISSING" in result.stdout:
            raise SystemExit(
                f"release build parameters: {WRAPPER} applied no override during the probe, "
                "so the release would build with the committed default (CI-08.3)")
        found = [line for line in result.stdout.splitlines()
                 if line.startswith("CJDOC_RECEIPT=")]
        if len(found) != 1:
            raise SystemExit(
                f"release build parameters: could not read the override receipt from "
                f"{WRAPPER}; wrapper output was: "
                f"{(result.stdout + result.stderr).strip()[-2000:]}")
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
