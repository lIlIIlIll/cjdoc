#!/usr/bin/env python3
"""The single definition of the STS build override (pinned Cangjie 1.2.0).

The pinned toolchain's bundled `llc` crashes at -O2 while compiling the markdown
and yjson dependencies, so every build/test/run is performed with
`override-compile-option` lowered to `OPTION` for the duration of one invocation.
`scripts/with_sts_o1_cjpm.sh` applies this by rewriting the affected manifests and
restoring them from a trap.

This module owns that rewrite so the wrapper and the CI-08.3 uniformity check
share one definition: the check computes the effective option by running
`apply_to` on the real manifest rather than by searching the wrapper's text or
repeating a constant, and no shell behaviour has to be probed (which is not
portable — the release matrix builds on Windows, where `bash` may be absent).
"""

from __future__ import annotations

import argparse
from pathlib import Path
import sys
import tomllib

sys.dont_write_bytecode = True

OPTION = "-O1"
NEEDLE = 'override-compile-option = ""'
MANIFEST_PACKAGE = {"cjpm.toml": "cjdoc", "tests/fixtures/projects/provider_plugin/cjpm.toml":
                    "provider_plugin_fixture"}


def apply_to(contents: str, expected_name: str) -> str:
    """Return `contents` as cjpm sees it during a wrapped invocation."""
    package = tomllib.loads(contents).get("package")
    if not isinstance(package, dict) or package.get("name") != expected_name:
        raise SystemExit(f"unexpected package manifest for {expected_name}")
    override = package.get("override-compile-option")
    if override == OPTION:
        return contents
    if override == "":
        if contents.count(NEEDLE) != 1:
            raise SystemExit(f"expected one default override-compile-option ({NEEDLE})")
        return contents.replace(NEEDLE, f'override-compile-option = "{OPTION}"', 1)
    if override is None:
        header = "[package]\n"
        if contents.count(header) != 1:
            raise SystemExit("expected one package table")
        return contents.replace(header, f'{header}  override-compile-option = "{OPTION}"\n', 1)
    raise SystemExit(f"unexpected compile override for {expected_name}")


def applied_option(contents: str, expected_name: str) -> str:
    """The override cjpm would actually use, read back from the rewritten text."""
    rewritten = tomllib.loads(apply_to(contents, expected_name))
    option = rewritten["package"].get("override-compile-option")
    return option if isinstance(option, str) else "<none>"


def main() -> int:
    parser = argparse.ArgumentParser(description="Report the override a manifest would build with.")
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--package", required=True)
    args = parser.parse_args()
    print(applied_option(args.manifest.read_text(encoding="utf-8"), args.package))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
