#!/usr/bin/env python3
"""Assert the release build parameters are uniform across platforms (CI-08.3).

#82 requires that if a platform needs different package build parameters, it must
produce its **own** candidate and be accepted against it, rather than reusing
another candidate's test conclusions. Today all three platforms share one build
command and one override, so the requirement holds by construction — but only an
absence enforced it. This check makes the determination explicit and fails loudly
the moment a platform diverges without the matching work.

Both facts are observed, each from the thing that actually decides:

* the compile option is read from **the manifest the real `cjpm` would read**, at the
  moment the wrapper delegates to it. A probe `cjpm` on PATH stands in for the real
  one and reports `override-compile-option` from `cjpm.toml`. The wrapper is executed
  rather than described, so its arguments, conditions and the rewrite itself are all
  exercised. Reading a receipt written by the patcher would not do: that is the
  patcher's own account, and it stays correct even if the manifest is never written;
* the build command is taken from the candidate job, where exactly one
  `cjpm\\s+build` may appear and it must be a bare `cjpm build …` line. Whitespace is
  normalised first, since `cjpm  build` is the same command to bash, and a build
  nested in `if …; then …; fi` is rejected because it would run on some platforms
  only.

Executing the wrapper requires a usable POSIX shell. The release candidate job runs
on `ubuntu-22.04`, so that is the platform this is written for; where no shell can
run, the check refuses instead of passing by default.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
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
CANDIDATE_JOB = "\n  release-candidate:\n"
PUBLISH_JOB = "\n  publish:\n"
# The option the pinned toolchain needs, and therefore the one the release requires.
REQUIRED_OPTION = "-O1"
# Unquoted metacharacters that turn one visible statement into several, or into a
# conditional one. A uniform command cannot contain any of them.
SHELL_CONTROL = "&|;<>`()"
CJPM_BUILD = re.compile(r"\bcjpm\s+build\b")
OBSERVED_PREFIX = "CJDOC_OBSERVED_OPTION="

# A `cjpm` that reports the manifest the wrapper has just patched, exactly as the
# real cjpm would read it. `__PYTHON__` is resolved to the running interpreter.
PROBE_CJPM = '''#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  -v|--version) exit 0 ;;
esac
"__PYTHON__" - "${GITHUB_WORKSPACE}/cjpm.toml" <<'PY'
import json, sys, tomllib
from pathlib import Path
package = tomllib.loads(Path(sys.argv[1]).read_text(encoding="utf-8")).get("package")
option = package.get("override-compile-option") if isinstance(package, dict) else None
print("__PREFIX__" + json.dumps(option))
PY
'''
PROBE_CJC = "#!/usr/bin/env bash\nexit 0\n"


class ParameterError(SystemExit):
    """A divergence that must stop the release (CI-08.3)."""

    def __init__(self, platform: str, detail: str) -> None:
        super().__init__(
            f"release build parameters: {platform} {detail}; a platform with distinct "
            "build parameters must produce its own candidate and run its own acceptance "
            "against that candidate (CI-08.3)")


def discover_build_command(workflow: Path) -> list[str]:
    """The single `cjpm build` the candidate job runs, or a refusal."""
    text = workflow.read_text(encoding="utf-8")
    if CANDIDATE_JOB not in text or PUBLISH_JOB not in text:
        raise SystemExit(f"release build parameters: {workflow} has no expected job layout")
    candidate = text.split(CANDIDATE_JOB, 1)[1].split(PUBLISH_JOB, 1)[0]
    # Join shell continuations first: a multi-line invocation is still one statement,
    # and a dangling backslash also makes shlex raise.
    executable = candidate.replace("\\\n", " ")
    lines = []
    for raw in executable.splitlines():
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        # Normalise whitespace: `cjpm  build` is the same command to bash.
        lines.append(re.sub(r"\s+", " ", stripped))

    # A shell function or alias named `cjpm` replaces the executable at the call
    # site, so the literal command would be a fiction: the workflow could still build
    # with different parameters. Reject any such definition in the build context.
    shadowing = [line for line in lines
                 if re.match(r"^(?:function\s+)?cjpm\s*\(\s*\)", line)
                 or re.match(r"^alias\s+cjpm=", line)]
    if shadowing:
        raise SystemExit(
            f"release build parameters: the candidate job defines {shadowing[0]!r}, so the "
            "`cjpm` that actually runs is not the released toolchain's and the build "
            "parameters cannot be vouched for (CI-08.3)")

    found = [(line, CJPM_BUILD.findall(line)) for line in lines]
    total = sum(len(matches) for _, matches in found)
    if total == 0:
        raise SystemExit(
            f"release build parameters: {workflow} candidate job never runs `cjpm build`, "
            "so its build parameters cannot be established (CI-08.3)")
    if total != 1:
        raise SystemExit(
            f"release build parameters: {workflow} candidate job runs `cjpm build` "
            f"{total} times, so the per-platform build parameters are no longer uniform "
            "and this check cannot vouch for them (CI-08.3)")
    statement = next(line for line, matches in found if matches)
    # `if …; then cjpm build …; fi` is a conditional build: it runs on some platforms
    # and not others, which is exactly what the uniformity claim must exclude.
    if not statement.startswith("cjpm build"):
        raise SystemExit(
            f"release build parameters: the candidate job's build line is {statement!r}, "
            "which is not a bare `cjpm build`; a build nested in a shell construct can "
            "run on some platforms only (CI-08.3)")
    command = shlex.split(statement)
    # Operators are found inside tokens too: `cjpm build --jobs 1&&cjpm build --jobs 4`
    # has ordinary tokens, yet bash runs two builds and packages the latter.
    control = []
    index = 0
    while index < len(statement):
        character = statement[index]
        if character in "'\"":
            closing = statement.find(character, index + 1)
            index = len(statement) if closing < 0 else closing + 1
            continue
        if character in SHELL_CONTROL:
            control.append(character)
        index += 1
    if control:
        raise SystemExit(
            f"release build parameters: the candidate job's build statement contains the "
            f"unquoted shell metacharacter {control[0]!r}, so it may run more than one "
            "build or build something other than one uniform command; make the single "
            "build explicit and give any platform that needs different parameters its "
            "own candidate (CI-08.3)")
    expansions = [token for token in command if "$" in token or "`" in token]
    if expansions:
        raise SystemExit(
            f"release build parameters: the candidate job builds with an interpolated "
            f"argument {expansions[0]!r}, so the effective parameters can differ per "
            "platform; make each platform's build explicit and give it its own "
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


def observed_option(repo: Path) -> str:
    """Run the wrapper and return the option the real `cjpm` would have read.

    The wrapper is the artefact under test, so it is executed. A probe `cjpm` reports
    the manifest at the moment the wrapper delegates to the build, which is the value
    the release would actually be compiled with.
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
        staging = Path(temporary).resolve()
        (staging / "cjpm.toml").write_bytes(manifest)
        runner_temp = staging / "runner-temp"
        probe_bin = runner_temp / "probe-bin"
        probe_bin.mkdir(parents=True)
        cjpm = (PROBE_CJPM.replace("__PYTHON__", sys.executable)
                .replace("__PREFIX__", OBSERVED_PREFIX))
        for name, body in (("cjpm", cjpm), ("cjc", PROBE_CJC)):
            binary = probe_bin / name
            binary.write_text(body, encoding="utf-8")
            binary.chmod(0o755)
        environment = dict(os.environ)
        environment.update({
            "GITHUB_WORKSPACE": str(staging),
            "RUNNER_TEMP": str(runner_temp),
            "CJDOC_STS_OVERRIDE_MODULE": str(repo / "scripts"),
            # Pin the patcher to the interpreter running this check: it is guaranteed
            # to exist, while a bare `python`/`python3` may not on every runner.
            "CJDOC_PYTHON": sys.executable,
            "PATH": f"{probe_bin}{os.pathsep}{environment.get('PATH', '')}",
        })
        # Keep the wrapper's output: without it a failure here is indistinguishable
        # from a genuinely missing override.
        command = f". {shlex.quote(str(repo / WRAPPER))} && cjpm build"
        try:
            result = subprocess.run([shell, "-c", command], cwd=staging, env=environment,
                                    capture_output=True, text=True, timeout=900)
        except (OSError, subprocess.SubprocessError) as error:
            raise SystemExit(f"release build parameters: could not run {WRAPPER}: {error}")
        if result.returncode != 0:
            raise SystemExit(
                f"release build parameters: {WRAPPER} exited {result.returncode} during the "
                f"probe: {(result.stderr or result.stdout).strip()[-2000:]}")
        observed = [line for line in result.stdout.splitlines()
                    if line.startswith(OBSERVED_PREFIX)]
        if len(observed) != 1:
            raise SystemExit(
                f"release build parameters: the wrapper did not reach the build with a "
                f"patched manifest; wrapper output was: "
                f"{(result.stdout + result.stderr).strip()[-2000:]}")
        option = json.loads(observed[0].split("=", 1)[1])
        # The rewrite must leave the tree it touched as it found it.
        if (staging / "cjpm.toml").read_bytes() != manifest:
            raise SystemExit(
                "release build parameters: the wrapper did not restore the manifest it "
                "patched, so the build parameters cannot be trusted")
        return option if isinstance(option, str) else "<none>"


def check(repo: Path, platform: str, workflow: Path) -> dict[str, object]:
    if platform not in PLATFORMS:
        raise SystemExit(f"release build parameters: unknown platform {platform!r}")
    for required in (WRAPPER, PATCHER, OVERRIDE_MODULE):
        if not (repo / required).is_file():
            raise SystemExit(f"release build parameters: missing {required}")
    command = discover_build_command(workflow)
    option = observed_option(repo)
    if option != REQUIRED_OPTION:
        raise ParameterError(
            platform,
            f"the build would read override-compile-option={option!r} from cjpm.toml, not "
            f"the required {REQUIRED_OPTION!r}")
    return {
        "schemaVersion": "cjdoc.release-build-parameters/1",
        "platform": platform,
        "command": command,
        "effectiveCompileOption": option,
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
