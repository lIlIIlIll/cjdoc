#!/usr/bin/env python3
"""The single definition of the STS build override (pinned Cangjie 1.2.0).

Product build/run invocations compile the root, worker and their dependencies
with -O2 --fno-chir-function-inlining. This extra option passed the same-source
Doc IR GC CLI regressions; it does not establish plain -O2 correctness or a
compiler root cause. Only `cjpm test` uses -O1: paired Linux runs with the same
STS 1.2.0 SDK, static stdx, stack 131072 and test argv fail with compiler ICE 13
under both plain -O2 and -O2 --fno-chir-function-inlining before any case runs.
Other platforms have not established a unit pass under either O2 configuration.
This is a selected phase policy, never a retry after failure.
`scripts/with_sts_cjpm.sh` applies the option and restores the manifests from a trap.

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

OPTION = "-O2 --fno-chir-function-inlining"
PRODUCT_OPTIONS = tuple(OPTION.split())
UNIT_OPTION = "-O1"
UNIT_REASON = "sts-1.2-linux-unit-plain-and-noinline-compiler-ice13"
PRODUCT_REASON = "sts-1.2-doc-ir-gc-no-chir-function-inlining"


def option_for(command: str) -> str:
    if command not in {"build", "test", "run"}:
        raise SystemExit(f"unsupported STS compile phase {command!r}")
    return UNIT_OPTION if command == "test" else OPTION


def phase_for(command: str) -> str:
    option_for(command)
    return {"build": "product-build", "test": "unit-test", "run": "product-run"}[command]


def reason_for(command: str) -> str:
    option_for(command)
    return UNIT_REASON if command == "test" else PRODUCT_REASON


NEEDLE = 'override-compile-option = ""'
# Only these repository/consumer entry packages receive the pinned STS override.
# Membership prevents rewriting unrelated manifests reachable from the workspace.
KNOWN_PACKAGES = ("cjdoc", "cjdoc_chir_worker", "provider_plugin_fixture", "highlight_host_fixture")


def manifest_package(contents: str) -> str:
    """The package a manifest declares, which must be one the release builds."""
    package = tomllib.loads(contents).get("package")
    if not isinstance(package, dict):
        raise SystemExit("manifest has no [package] table")
    name = package.get("name")
    if name not in KNOWN_PACKAGES:
        raise SystemExit(f"unexpected package manifest {name!r}")
    return str(name)


def apply_to(contents: str, command: str = "build") -> str:
    """Return `contents` as cjpm sees it during a wrapped invocation."""
    package = tomllib.loads(contents).get("package")
    assert isinstance(package, dict)  # manifest_package validated the shape
    manifest_package(contents)
    option = option_for(command)
    override = package.get("override-compile-option")
    if override == option:
        return contents
    if override in {"", OPTION, UNIT_OPTION}:
        # A nested product consumer during a unit test temporarily replaces the
        # outer test's -O1, then its wrapper restores that exact outer manifest.
        needle = f'override-compile-option = "{override}"'
        if contents.count(needle) != 1:
            raise SystemExit(f"expected one override-compile-option ({needle})")
        return contents.replace(needle, f'override-compile-option = "{option}"', 1)
    if override is None:
        header = "[package]\n"
        if contents.count(header) != 1:
            raise SystemExit("expected one package table")
        return contents.replace(header, f'{header}  override-compile-option = "{option}"\n', 1)
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


def applied_option(contents: str, command: str = "build") -> str:
    """The override cjpm would actually use, read back from the rewritten text."""
    rewritten = tomllib.loads(apply_to(contents, command))
    option = rewritten["package"].get("override-compile-option")
    return option if isinstance(option, str) else "<none>"


def main() -> int:
    parser = argparse.ArgumentParser(description="Report a manifest's compile override.")
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--command", choices=("build", "test", "run"), default="build")
    parser.add_argument("--declared", action="store_true",
                        help="report what the manifest declares now, not the rewrite")
    args = parser.parse_args()
    contents = args.manifest.read_text(encoding="utf-8")
    print(declared_option(contents) if args.declared else applied_option(contents, args.command))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
