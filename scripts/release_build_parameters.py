#!/usr/bin/env python3
"""Assert the release build parameters are uniform across platforms (CI-08.3).

#82 requires that if a platform needs different package build parameters, it must
produce its **own** candidate and be accepted against it, rather than reusing
another candidate's test conclusions. Today all three platforms share one build
command and one `-O1` override, so the requirement holds by construction — but
only an absence enforced it. This check makes the determination explicit and
fails loudly the moment a platform diverges without the matching work.

Two facts are established, both from the real artefacts rather than from prose:

* the build command is **parsed out of the release workflow's candidate job**, so
  a platform-specific invocation added through an array or an extra line cannot
  hide behind a matching prefix;
* the effective compile option is obtained by **running the `-O1` wrapper** with a
  probe `cjpm` on PATH and reading the manifest as the wrapper leaves it during
  the call. The override is applied transiently (`cjpm.toml` deliberately commits
  `""`), so searching the wrapper's text would prove nothing — its own comments
  already contain the literal.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True

PLATFORMS = ("linux-x64", "windows-x64", "macos-arm64")
WORKFLOW = Path(".github/workflows/release.yml")
WRAPPER = Path("scripts/with_sts_o1_cjpm.sh")
CANDIDATE_JOB = "\n  release-candidate:\n"
PUBLISH_JOB = "\n  publish:\n"
PROBE_MARKER = "CJDOC_PROBE_OVERRIDE="

# A `cjpm` that reports the manifest the wrapper has just patched, and a `cjc`
# good enough for the wrapper's own `-v` sanity checks. The wrapper's trap
# restores the original manifest, so probing leaves nothing behind.
PROBE_CJPM = f'''#!/usr/bin/env bash
set -euo pipefail
case "${{1:-}}" in
  -v|--version) exit 0 ;;
esac
python3 - "${{GITHUB_WORKSPACE}}/cjpm.toml" <<'PY'
import json, sys, tomllib
from pathlib import Path
package = tomllib.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))["package"]
print("{PROBE_MARKER}" + json.dumps(package.get("override-compile-option")))
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


def probe_effective_option(repo: Path, workspace: Path, runner_temp: Path) -> str:
    """Run the wrapper and read the override as it applies during the call."""
    probe_dir = runner_temp / "probe-bin"
    probe_dir.mkdir(parents=True, exist_ok=True)
    for name, body in (("cjpm", PROBE_CJPM), ("cjc", PROBE_CJC)):
        binary = probe_dir / name
        binary.write_text(body, encoding="utf-8")
        binary.chmod(0o755)
    environment = dict(os.environ)
    environment.update({
        "GITHUB_WORKSPACE": str(workspace),
        "RUNNER_TEMP": str(runner_temp),
        "PATH": f"{probe_dir}{os.pathsep}{environment.get('PATH', '')}",
    })
    # `cjpm build` inside the workspace is the only invocation the wrapper
    # rewrites; anything else passes straight through.
    command = f". {shlex.quote(str(repo / WRAPPER))} >/dev/null 2>&1 && cjpm build"
    try:
        result = subprocess.run(["bash", "-c", command], cwd=workspace, env=environment,
                                capture_output=True, text=True, timeout=600)
    except (OSError, subprocess.SubprocessError) as error:
        raise SystemExit(f"release build parameters: could not probe {WRAPPER}: {error}")
    if result.returncode != 0:
        raise SystemExit(
            f"release build parameters: probing {WRAPPER} failed with "
            f"{result.returncode}: {result.stderr.strip() or result.stdout.strip()}")
    found = re.search(rf"{PROBE_MARKER}(.+)", result.stdout)
    if not found:
        raise SystemExit(
            f"release build parameters: {WRAPPER} did not apply an override during the "
            "probe, so the release would be built with the committed default (CI-08.3)")
    option = json.loads(found.group(1))
    return option if isinstance(option, str) else "<none>"


def check(repo: Path, platform: str, workflow: Path) -> dict[str, object]:
    if platform not in PLATFORMS:
        raise SystemExit(f"release build parameters: unknown platform {platform!r}")
    if not (repo / WRAPPER).is_file():
        raise SystemExit(f"release build parameters: missing {WRAPPER}")
    command = discover_build_command(workflow)
    manifest = repo / "cjpm.toml"
    with tempfile.TemporaryDirectory(prefix="cjdoc-build-params-") as temporary:
        staging = Path(temporary)
        (staging / "cjpm.toml").write_bytes(manifest.read_bytes())
        effective = probe_effective_option(repo, staging, staging / "runner-temp")
        # The probe must leave the tree it touched exactly as it found it.
        restored = (staging / "cjpm.toml").read_bytes()
    if restored != manifest.read_bytes():
        raise SystemExit(
            "release build parameters: the wrapper probe did not restore the manifest "
            "it patched, so the build parameters cannot be trusted")
    if effective != "-O1":
        raise ParameterError(platform, f"would build with override-compile-option={effective!r}, "
                                       "not the shared '-O1'")
    return {
        "schemaVersion": "cjdoc.release-build-parameters/1",
        "platform": platform,
        "command": command,
        "effectiveCompileOption": effective,
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
    # Resolve before probing: the probe runs in a temporary directory, so a
    # relative --repo would make the wrapper unreachable from there.
    repo = args.repo.resolve()
    workflow = (args.workflow.resolve() if args.workflow else repo / WORKFLOW)
    print(json.dumps(check(repo, args.platform, workflow), ensure_ascii=False,
                     sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
