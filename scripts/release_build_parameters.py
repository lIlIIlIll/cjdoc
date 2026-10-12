#!/usr/bin/env python3
"""Assert the release build parameters are uniform across platforms (CI-08.3).

#82 requires that if a platform needs different package build parameters, it must
produce its **own** candidate and be accepted against it, rather than reusing
another candidate's test conclusions. Today all three platforms share one build
command and one `-O1` override, so the requirement holds by construction — but
only an absence enforced it. This check makes the determination explicit and
fails loudly the moment a platform diverges without the matching work.

The `-O1` override is applied *transiently* by `scripts/with_sts_o1_cjpm.sh`,
which rewrites `override-compile-option` for the duration of one `cjpm`
invocation and restores it afterwards. So the effective parameters are observed
through the wrapper being active (`CJDOC_REAL_CJPM`), not by reading the
committed manifest, whose override is deliberately empty.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import sys
import tomllib

sys.dont_write_bytecode = True

PLATFORMS = ("linux-x64", "windows-x64", "macos-arm64")
# The single build command the release candidate job runs for every platform.
SHARED_BUILD_COMMAND = ["cjpm", "build", "--jobs", "1"]
WRAPPER = Path("scripts/with_sts_o1_cjpm.sh")
WRAPPER_OVERRIDE = 'override-compile-option = "-O1"'


def check(repo: Path, platform: str, expect_option: str) -> dict[str, object]:
    if platform not in PLATFORMS:
        raise SystemExit(f"release build parameters: unknown platform {platform!r}")
    # The wrapper must be active; otherwise `cjpm build` would use the committed
    # (empty) override and quietly change what the release was built with.
    if not os.environ.get("CJDOC_REAL_CJPM"):
        raise SystemExit(
            f"release build parameters: {platform} is about to build without the -O1 "
            "wrapper active (CJDOC_REAL_CJPM is unset); source scripts/with_sts_o1_cjpm.sh "
            "first, or the release parameters no longer match the other platforms")
    wrapper = repo / WRAPPER
    if not wrapper.is_file():
        raise SystemExit(f"release build parameters: missing {WRAPPER}")
    text = wrapper.read_text(encoding="utf-8")
    # The wrapper is the single definition of the override; if it stops forcing
    # -O1, every platform silently changes what it builds.
    if f"'{WRAPPER_OVERRIDE}'" not in text and WRAPPER_OVERRIDE not in text:
        raise SystemExit(
            f"release build parameters: {WRAPPER} no longer forces {WRAPPER_OVERRIDE!r}; "
            "a changed compile option needs a fresh candidate per platform (CI-08.3)")
    manifest = tomllib.loads((repo / "cjpm.toml").read_text(encoding="utf-8"))
    committed = manifest.get("package", {}).get("override-compile-option")
    if committed not in ("", expect_option):
        raise SystemExit(
            f"release build parameters: cjpm.toml commits override-compile-option="
            f"{committed!r}, which is neither the shared default nor {expect_option!r}; "
            "a platform with distinct build parameters must produce its own candidate "
            "and run its own acceptance against it (CI-08.3)")
    return {
        "schemaVersion": "cjdoc.release-build-parameters/1",
        "platform": platform,
        "command": SHARED_BUILD_COMMAND,
        "effectiveCompileOption": expect_option,
        "wrapper": WRAPPER.as_posix(),
        "wrapperSha256": hashlib.sha256(wrapper.read_bytes()).hexdigest(),
        "uniformAcross": list(PLATFORMS),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--platform", required=True, choices=PLATFORMS)
    parser.add_argument("--expect-compile-option", default="-O1")
    args = parser.parse_args()
    print(json.dumps(check(args.repo, args.platform, args.expect_compile_option),
                     ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
