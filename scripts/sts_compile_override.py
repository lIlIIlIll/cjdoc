#!/usr/bin/env python3
"""The single definition of the STS build override (pinned Cangjie 1.2.0).

The pinned toolchain's bundled `llc` crashes at -O2 while compiling the markdown
and yjson dependencies, so every build/test/run is performed with
`override-compile-option` lowered to `OPTION` for the duration of one invocation.
`scripts/with_sts_o1_cjpm.sh` applies this by rewriting the affected manifests and
restoring them from a trap.

This module owns that rewrite so the wrapper and the CI-08.3 uniformity check
share one definition. The package name is read from each manifest and checked
against `KNOWN_PACKAGES`, never supplied by the caller: deriving it from a path
gave the wrong answer for the provider fixture, whose directory and package names
differ, and a caller-supplied name would let the wrapper be pointed at a manifest
the release does not build.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import sys
import tomllib

sys.dont_write_bytecode = True

OPTION = "-O1"
NEEDLE = 'override-compile-option = ""'
# Only these repository/consumer packages need the pinned STS override.
# Membership prevents rewriting unrelated manifests reachable from the workspace.
KNOWN_PACKAGES = ("cjdoc", "provider_plugin_fixture", "highlight_host_fixture")


def manifest_package(contents: str) -> str:
    """The package a manifest declares, which must be one the release builds."""
    package = tomllib.loads(contents).get("package")
    if not isinstance(package, dict):
        raise SystemExit("manifest has no [package] table")
    name = package.get("name")
    if name not in KNOWN_PACKAGES:
        raise SystemExit(f"unexpected package manifest {name!r}")
    return str(name)


def apply_to(contents: str) -> str:
    """Return `contents` as cjpm sees it during a wrapped invocation."""
    package = tomllib.loads(contents).get("package")
    assert isinstance(package, dict)  # manifest_package validated the shape
    manifest_package(contents)
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
    raise SystemExit(f"unexpected compile override {override!r}")


def declared_option(contents: str) -> str:
    """The override a manifest declares *now*, without modelling the rewrite.

    Used where the question is what a given `cjpm` invocation will actually read: the
    wrapper patches the workspace manifest, but `cjpm` run inside an auxiliary project
    (for example `tools/chir-worker`) reads that project's own manifest, which may
    declare no override at all. Applying the rewrite here would report the value the
    root manifest receives rather than the one the invocation consumes.
    """
    package = tomllib.loads(contents).get("package")
    if not isinstance(package, dict):
        raise SystemExit("manifest has no [package] table")
    option = package.get("override-compile-option")
    return option if isinstance(option, str) else "<none>"


def applied_option(contents: str) -> str:
    """The override cjpm would actually use, read back from the rewritten text."""
    rewritten = tomllib.loads(apply_to(contents))
    option = rewritten["package"].get("override-compile-option")
    return option if isinstance(option, str) else "<none>"


def main() -> int:
    parser = argparse.ArgumentParser(description="Report a manifest's compile override.")
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--declared", action="store_true",
                        help="report what the manifest declares now, not the rewrite")
    args = parser.parse_args()
    contents = args.manifest.read_text(encoding="utf-8")
    print(declared_option(contents) if args.declared else applied_option(contents))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
