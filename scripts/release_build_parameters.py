#!/usr/bin/env python3
"""Confirm the pinned STS build override is the one the release would apply (CI-08.3).

This is the *observation* half of CI-08.3, and it deliberately says nothing about
the workflow's text. It runs `scripts/with_sts_o1_cjpm.sh` with a probe `cjpm` on
PATH and reads back the override from the manifest at the moment the wrapper
delegates to the build — so the value comes from the artefact the release would
consume, not from a pattern in a file.

Why the command text is not checked here: enumerating ways a build can be spelled,
nested, aliased, shadowed or referenced indirectly is not a finite job, and each
round of it produced a false voucher. The question "did every build run with the
vouched command and option, and is the packaged binary the one that build produced?"
is answered from the record the wrapper writes as it runs — see
`verify_build_invocations.py`, which is the guard. A build routed around the wrapper
leaves no record, and one that replaced the binary changes its digest, so neither
depends on recognising a spelling.

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
import shlex
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True

PLATFORMS = ("linux-x64", "windows-x64", "macos-arm64")
WRAPPER = Path("scripts/with_sts_o1_cjpm.sh")
PATCHER = Path("scripts/apply_sts_override.py")
OVERRIDE_MODULE = Path("scripts/sts_compile_override.py")
REQUIRED_OPTION = "-O1"
OBSERVED_PREFIX = "CJDOC_OBSERVED_OPTION="

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
    """Run the wrapper and return the option the real `cjpm` would have read."""
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
            # The probe runs the real wrapper, which records its invocations. In CI the
            # release step exports the production log path before running `check.sh`,
            # whose unit stage runs this check — inheriting it would append fake records
            # to the release's evidence. Keep the probe's records in the staging
            # directory.
            "CJDOC_STS_INVOCATION_LOG": str(staging / "probe-invocations.jsonl"),
            "PATH": f"{probe_bin}{os.pathsep}{environment.get('PATH', '')}",
        })
        command = f". {shlex.quote(str(repo / WRAPPER))} && cjpm build --jobs 1"
        try:
            result = subprocess.run([shell, "-c", command], cwd=staging, env=environment,
                                    capture_output=True, text=True, timeout=900)
        except (OSError, subprocess.SubprocessError) as error:
            raise SystemExit(f"release build parameters: could not run {WRAPPER}: {error}")
        if result.returncode != 0:
            raise SystemExit(
                f"release build parameters: {WRAPPER} exited {result.returncode} while "
                f"observing the override: "
                f"{(result.stderr or result.stdout).strip()[-2000:]}")
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


def check(repo: Path, platform: str) -> dict[str, object]:
    if platform not in PLATFORMS:
        raise SystemExit(f"release build parameters: unknown platform {platform!r}")
    for required in (WRAPPER, PATCHER, OVERRIDE_MODULE):
        if not (repo / required).is_file():
            raise SystemExit(f"release build parameters: missing {required}")
    option = observed_option(repo)
    if option != REQUIRED_OPTION:
        raise ParameterError(
            platform,
            f"the build would read override-compile-option={option!r} from cjpm.toml, not "
            f"the required {REQUIRED_OPTION!r}")
    return {
        "schemaVersion": "cjdoc.release-build-parameters/1",
        "platform": platform,
        "effectiveCompileOption": option,
        "wrapper": WRAPPER.as_posix(),
        "wrapperSha256": hashlib.sha256((repo / WRAPPER).read_bytes()).hexdigest(),
        "uniformAcross": list(PLATFORMS),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--platform", required=True, choices=PLATFORMS)
    args = parser.parse_args()
    repo = args.repo.resolve()
    print(json.dumps(check(repo, args.platform), ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
