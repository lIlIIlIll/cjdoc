#!/usr/bin/env python3
"""Assert the release build parameters are uniform across platforms (CI-08.3).

#82 requires that if a platform needs different package build parameters, it must
produce its **own** candidate and be accepted against it, rather than reusing
another candidate's test conclusions. Today all three platforms share one build
command and one override, so the requirement holds by construction — but only an
absence enforced it. This check makes the determination explicit and fails loudly
the moment a platform diverges without the matching work.

Two facts are established from real artefacts rather than from prose:

* the build command is **parsed out of the release workflow's candidate job** and
  must be a plain literal, so a platform-specific invocation cannot hide behind a
  matching prefix;
* the effective compile option is computed by running the **same function the
  `-O1` wrapper runs** (`scripts/sts_compile_override.apply_to`) over the real
  manifest. It is not read from `cjpm.toml`, which deliberately commits `""`, and
  it is not searched for in the wrapper's text, whose comments already contain the
  literal. It is also not probed by executing the wrapper, because that would make
  the check depend on a POSIX shell on every platform — and the release matrix builds on
  Windows, where no POSIX shell is guaranteed.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import importlib.util
import shlex
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True

OVERRIDE_MODULE = Path("scripts/sts_compile_override.py")


def load_override_module(repo: Path):
    """Load the shared definition from the repository under test.

    Importing it from this script's own directory would verify a different tree
    than the one being released — and in CI the two are the same, so the mistake
    would be invisible there and only surface as a wrong voucher under mutation.
    """
    path = repo / OVERRIDE_MODULE
    if not path.is_file():
        raise SystemExit(f"release build parameters: missing {OVERRIDE_MODULE}")
    spec = importlib.util.spec_from_file_location("cjdoc_sts_compile_override", path)
    if spec is None or spec.loader is None:
        raise SystemExit(f"release build parameters: cannot load {OVERRIDE_MODULE}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

PLATFORMS = ("linux-x64", "windows-x64", "macos-arm64")
WORKFLOW = Path(".github/workflows/release.yml")
WRAPPER = Path("scripts/with_sts_o1_cjpm.sh")
PATCHER = Path("scripts/apply_sts_override.py")
CANDIDATE_JOB = "\n  release-candidate:\n"
PUBLISH_JOB = "\n  publish:\n"
ROOT_PACKAGE = "cjdoc"
# The option the pinned toolchain needs (see scripts/sts_compile_override.py).
REQUIRED_OPTION = "-O1"


class ParameterError(SystemExit):
    """A divergence that must stop the release (CI-08.3)."""

    def __init__(self, platform: str, detail: str) -> None:
        super().__init__(
            f"release build parameters: {platform} {detail}; a platform with distinct "
            "build parameters must produce its own candidate and run its own acceptance "
            "against that candidate (CI-08.3)")


def discover_build_command(workflow: Path) -> list[str]:
    """Return the single `cjpm` invocation the candidate job actually runs."""
    text = workflow.read_text(encoding="utf-8")
    if CANDIDATE_JOB not in text or PUBLISH_JOB not in text:
        raise SystemExit(f"release build parameters: {workflow} has no expected job layout")
    candidate = text.split(CANDIDATE_JOB, 1)[1].split(PUBLISH_JOB, 1)[0]
    calls = [line.strip() for line in candidate.splitlines()
             if line.strip().startswith("cjpm ")]
    if len(calls) != 1:
        raise SystemExit(
            f"release build parameters: {workflow} candidate job runs {len(calls)} cjpm "
            "commands, so the per-platform build parameters are no longer uniform and "
            "this check cannot vouch for them (CI-08.3)")
    command = shlex.split(calls[0])
    # A conditional or interpolated invocation (e.g. an `extra` array selected per
    # platform) yields a different effective command per platform while still
    # looking uniform here. Require a plain literal so the recorded command is the
    # one that actually runs on every platform.
    expansions = [token for token in command if "$" in token or "`" in token]
    if expansions:
        raise SystemExit(
            f"release build parameters: {workflow} builds with an interpolated argument "
            f"{expansions[0]!r}, so the effective parameters can differ per platform; "
            "make each platform's build explicit and give it its own candidate (CI-08.3)")
    return command


def wrapper_patch_command(wrapper: Path) -> str:
    """The executable line by which the wrapper applies the override.

    The wrapper must delegate to `scripts/apply_sts_override.py`; if it stops doing
    so, or grows its own inline rewrite, the option this check computes is no longer
    the option that gets built and the uniformity claim would be worthless.
    """
    text = wrapper.read_text(encoding="utf-8")
    lines = [line.strip() for line in text.splitlines()
             if line.strip() and not line.lstrip().startswith("#")]
    delegates = [line for line in lines if PATCHER.name in line]
    if len(delegates) != 1:
        raise SystemExit(
            f"release build parameters: {WRAPPER} does not invoke {PATCHER} exactly once, "
            "so the effective option cannot be established and the platforms cannot be "
            "shown to be uniform (CI-08.3)")
    inline = [line for line in lines if "override-compile-option" in line
              and PATCHER.name not in line]
    if inline:
        raise SystemExit(
            f"release build parameters: {WRAPPER} contains its own override rewrite in "
            "addition to the shared definition; the two can drift, so the uniformity "
            "claim is unprovable (CI-08.3)")
    return delegates[0]


def effective_option(repo: Path, wrapper: Path, override) -> str:
    """Run the wrapper's own patch command and read back what it applies.

    Executing the command — rather than searching the wrapper's text, or calling the
    shared function directly — means the value is taken from the real call path, in
    Python, so it also works on the Windows and macOS release legs.
    """
    wrapper_patch_command(wrapper)
    manifest = repo / "cjpm.toml"
    before = manifest.read_bytes()
    with tempfile.TemporaryDirectory(prefix="cjdoc-build-params-") as temporary:
        staging = Path(temporary)
        target = staging / "cjpm.toml"
        target.write_bytes(before)
        backup_dir = staging / "backup"
        command = [sys.executable, str(repo / PATCHER), str(target), str(backup_dir)]
        result = subprocess.run(command, cwd=repo, capture_output=True, text=True,
                                timeout=600)
        if result.returncode != 0:
            raise SystemExit(
                f"release build parameters: {PATCHER} failed with {result.returncode}: "
                f"{result.stderr.strip() or result.stdout.strip()}")
        option = override.applied_option(target.read_text(encoding="utf-8"), ROOT_PACKAGE)
        if target.read_bytes() == before:
            raise SystemExit(
                f"release build parameters: {PATCHER} applied no override to cjpm.toml, so "
                "the release would build with the committed default (CI-08.3)")
    return option


def check(repo: Path, platform: str, workflow: Path) -> dict[str, object]:
    if platform not in PLATFORMS:
        raise SystemExit(f"release build parameters: unknown platform {platform!r}")
    if not (repo / WRAPPER).is_file():
        raise SystemExit(f"release build parameters: missing {WRAPPER}")
    command = discover_build_command(workflow)
    override = load_override_module(repo)
    if not (repo / PATCHER).is_file():
        raise SystemExit(f"release build parameters: missing {PATCHER}")
    effective = effective_option(repo, repo / WRAPPER, override)
    # Two independent facts: the definition the release mandates must still be the
    # required option, and the value the wrapper's own call path produces must equal
    # it. Without the first, the shared definition could change and every platform
    # would still agree with itself.
    if override.OPTION != REQUIRED_OPTION:
        raise ParameterError(
            platform,
            f"the shared override definition now applies {override.OPTION!r}, but the "
            f"release requires {REQUIRED_OPTION!r}")
    if effective != REQUIRED_OPTION:
        raise ParameterError(
            platform,
            f"would build with override-compile-option={effective!r}, "
            f"not the required {REQUIRED_OPTION!r}")
    return {
        "schemaVersion": "cjdoc.release-build-parameters/1",
        "platform": platform,
        "command": command,
        "effectiveCompileOption": effective,
        "overrideModule": OVERRIDE_MODULE.as_posix(),
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
