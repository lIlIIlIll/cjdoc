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

Both phases additionally suppress the `unused` and `deprecated` warning groups.
Every warning STS 1.2 emits for this tree today falls into one of those two
groups, and most of them cannot be fixed here: 25 come from inside the pinned
`yjson` dependency, 16 are test-only helpers that a product build never reaches,
726 on macOS are mock variables synthesized inside the `@Test` macro, and 42 are
`std.posix` fd calls (`openat`, `O_NOFOLLOW`, `lseek`, ...) whose replacement
`std.fs` API cannot express the descriptor-relative, no-symlink walk that
`src/filesystem/bounded_read.cj` requires. Suppressing them removed 86% of the
build log without hiding any report the compiler still produces: `parser`,
`semantics`, `apilevel-check`, `unsupport-compile-source`, `package-import` and
`interpreter` stay enabled, which is why `all` is not used here.

The suppression is part of the manifest override, so `cjpm` applies it to every
package it compiles -- cjdoc and its dependencies alike. That is the accepted
cost: a newly dead symbol or a newly deprecated API call in this repository will
not announce itself in the build log, so review and the lint stage are the only
remaining signal for those two groups.

This module owns that rewrite so the wrapper and the CI-08.3 uniformity check
share one definition. The package name is read from each manifest and checked
against `KNOWN_PACKAGES`, never supplied by the caller: deriving it from a path
gave the wrong answer for the provider fixture, whose directory and package names
differ, and a caller-supplied name would let the wrapper be pointed at a manifest
the release does not build.

A provider-fixture product invocation may additionally request compiler
diagnostics through `CJDOC_STS_COMPILER_DIAGNOSTICS`. That appends `-V` and
`--save-temps DIR` to the same policy option: the optimisation level is unchanged,
so the retained IR belongs to the same build, and the request is only honoured for
that one fixture and phase.
"""

from __future__ import annotations

import argparse
import re
import sys
import tomllib
from pathlib import Path, PurePath, PureWindowsPath

sys.dont_write_bytecode = True

# `cjpm` splits this value itself on spaces; each flag/value pair stays two tokens.
WARNING_SUPPRESSION = ("-Woff", "unused", "-Woff", "deprecated")
PRODUCT_OPTIMISATION = "-O2 --fno-chir-function-inlining"
UNIT_OPTIMISATION = "-O1"
OPTION = " ".join((PRODUCT_OPTIMISATION, *WARNING_SUPPRESSION))
PRODUCT_OPTIONS = tuple(OPTION.split())
UNIT_OPTION = " ".join((UNIT_OPTIMISATION, *WARNING_SUPPRESSION))
UNIT_OPTIONS = tuple(UNIT_OPTION.split())
UNIT_REASON = "sts-1.2-linux-unit-plain-and-noinline-compiler-ice13"
PRODUCT_REASON = "sts-1.2-doc-ir-gc-no-chir-function-inlining"
# Set for one provider-fixture product invocation by the native compiler capture.
DIAGNOSTICS_ENVIRONMENT = "CJDOC_STS_COMPILER_DIAGNOSTICS"
# Retention flags appended to the policy option for that invocation only.
DIAGNOSTIC_COMPILER_FLAGS = ("-V", "--save-temps")
PHASE_DIAGNOSTICS_REFUSAL = (
    "compiler diagnostics are recorded for the provider fixture's product run only; "
    "every other phase keeps the pinned option and its own target")


def option_for(command: str) -> str:
    if command not in {"build", "test", "run"}:
        raise SystemExit(f"unsupported STS compile phase {command!r}")
    return UNIT_OPTION if command == "test" else OPTION


def diagnostics_directory(value: str | PurePath) -> str:
    """Validate a diagnostics directory as a TOML value and as a `cjpm` argument.

    `cjpm` does not run a shell: it splits `override-compile-option` itself,
    using spaces as separators and `"` as a grouping delimiter, and it treats a
    `"` preceded by a backslash as escaped rather than as the end of a group. The
    value is therefore neither shell text nor free-form: these checks refuse the
    shapes that splitter and cjpm's own manifest validation cannot carry, so a
    request to retain compiler output can never silently compile with a
    truncated path or a different option set.
    """
    text = str(value)
    if not text:
        raise SystemExit("compiler diagnostics directory is empty")
    if not (PurePath(text).is_absolute() or PureWindowsPath(text).is_absolute()):
        raise SystemExit(f"compiler diagnostics directory is not absolute: {text!r}")
    for character, description in (("\0", "a NUL byte"), ("\n", "a newline"),
                                   ("\r", "a carriage return"),
                                   ('"', "a double quote")):
        if character in text:
            raise SystemExit(
                f"compiler diagnostics directory contains {description}: {text!r}")
    # cjpm refuses an override carrying this pattern outright, so the failure is
    # reported here against the directory that caused it instead of as a manifest
    # cjpm will not read.
    for character in "|;&$><`!":
        if character in text:
            raise SystemExit(
                f"compiler diagnostics directory contains {character!r}, which cjpm "
                f"refuses in override-compile-option: {text!r}")
    if text.endswith("\\"):
        # cjpm would read the closing quote of the argument as escaped and treat
        # the rest of the option as one unterminated string.
        raise SystemExit(
            "compiler diagnostics directory ends with a backslash, which makes cjpm "
            f"read the closing quote as escaped: {text!r}")
    return text


def invocation_option(command: str, diagnostics_dir: str | PurePath | None = None) -> str:
    """The override one invocation consumes: the phase policy, plus retention.

    Retention is a diagnostic extra, not a change of policy: the optimisation
    option and its phase selection are identical with and without it, so the
    saved IR describes the same build. Only the product run that the capture
    asks for can receive it; a build keeps the pinned option without retention,
    so no artefact compiled for the release gets a different flag set.
    """
    option = option_for(command)
    if diagnostics_dir is None:
        return option
    if command != "run":
        raise SystemExit(PHASE_DIAGNOSTICS_REFUSAL)
    directory = diagnostics_directory(diagnostics_dir)
    return f'{option} {" ".join(DIAGNOSTIC_COMPILER_FLAGS)} "{directory}"'


def toml_basic_string(value: str) -> str:
    """Escape `value` for the inside of a TOML basic string.

    A Windows directory carries backslashes, which a TOML basic string reads as
    the start of an escape sequence unless they are doubled. The result is what
    a TOML reader decodes back to exactly `value`.
    """
    escaped = []
    for character in value:
        code = ord(character)
        if character == "\\":
            escaped.append("\\\\")
        elif character == '"':
            escaped.append('\\"')
        elif character == "\t":
            escaped.append("\\t")
        elif character == "\n":
            escaped.append("\\n")
        elif character == "\r":
            escaped.append("\\r")
        elif code < 0x20 or code == 0x7F:
            escaped.append(f"\\u{code:04X}")
        else:
            escaped.append(character)
    return "".join(escaped)


def phase_for(command: str) -> str:
    option_for(command)
    return {"build": "product-build", "test": "unit-test", "run": "product-run"}[command]


def reason_for(command: str) -> str:
    option_for(command)
    return UNIT_REASON if command == "test" else PRODUCT_REASON


# The single assignment the rewrite replaces. TOML allows spacing around `=` and
# escapes inside a basic string, so the value is matched as text and decoded back
# rather than assumed to be exactly the string this module wrote last time.
OVERRIDE_ASSIGNMENT = re.compile(
    r'^(?P<indent>[ \t]*)override-compile-option[ \t]*=[ \t]*"(?:\\[^\n]|[^"\\\n])*"',
    re.MULTILINE)
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


def is_known_override(value: str) -> bool:
    """Whether a declared override is one this module may rewrite.

    A diagnostics-bearing override is the policy option with the retention flags
    appended and exactly one quoted directory. Accepting it keeps the rewrite
    total over the states this repository's own wrappers can leave behind, while
    an unrelated option is refused rather than silently replaced.
    """
    if value in {"", OPTION, UNIT_OPTION}:
        return True
    prefix = f'{OPTION} {" ".join(DIAGNOSTIC_COMPILER_FLAGS)} "'
    if not value.startswith(prefix) or not value.endswith('"'):
        return False
    return '"' not in value[len(prefix):-1]


def replace_assignment(contents: str, option: str, declared: str) -> str:
    """Replace the manifest's one `override-compile-option` assignment.

    Locating it as text rather than by reconstructing the previous declaration
    means spacing, escapes and a nested consumer's diagnostic suffix all keep
    working; anything else in the file is left byte-identical. The matched text
    is decoded back and compared with the value TOML reported, so the span being
    rewritten is proven to be the field `cjpm` reads.
    """
    assignments = list(OVERRIDE_ASSIGNMENT.finditer(contents))
    if len(assignments) != 1:
        raise SystemExit(
            "expected one basic-string override-compile-option assignment, found "
            f"{len(assignments)}")
    assignment = assignments[0]
    matched = tomllib.loads("[package]\n" + assignment.group(0))["package"]
    if matched.get("override-compile-option") != declared:
        raise SystemExit(
            "the override-compile-option assignment matched by text is not the one "
            f"TOML reports: {matched.get('override-compile-option')!r} vs {declared!r}")
    return (contents[:assignment.start()]
            + f'{assignment.group("indent")}override-compile-option = "{toml_basic_string(option)}"'
            + contents[assignment.end():])


def apply_to(contents: str, command: str = "build",
             diagnostics_dir: str | PurePath | None = None) -> str:
    """Return `contents` as cjpm sees it during a wrapped invocation."""
    package = tomllib.loads(contents).get("package")
    assert isinstance(package, dict)  # manifest_package validated the shape
    manifest_package(contents)
    option = invocation_option(command, diagnostics_dir)
    override = package.get("override-compile-option")
    if override == option:
        return contents
    if isinstance(override, str) and is_known_override(override):
        # A nested product consumer during a unit test temporarily replaces the
        # outer test's -O1, then its wrapper restores that exact outer manifest.
        return replace_assignment(contents, option, override)
    if override is None:
        header = "[package]\n"
        if contents.count(header) != 1:
            raise SystemExit("expected one package table")
        return contents.replace(
            header, f'{header}  override-compile-option = "{toml_basic_string(option)}"\n', 1)
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


def applied_option(contents: str, command: str = "build",
                   diagnostics_dir: str | PurePath | None = None) -> str:
    """The override cjpm would actually use, read back from the rewritten text."""
    rewritten = tomllib.loads(apply_to(contents, command, diagnostics_dir))
    option = rewritten["package"].get("override-compile-option")
    return option if isinstance(option, str) else "<none>"


def main() -> int:
    parser = argparse.ArgumentParser(description="Report a manifest's compile override.")
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--command", choices=("build", "test", "run"), default="build")
    parser.add_argument("--declared", action="store_true",
                        help="report what the manifest declares now, not the rewrite")
    parser.add_argument("--diagnostics-dir", type=Path,
                        help="report the override with compiler diagnostics retained there")
    args = parser.parse_args()
    contents = args.manifest.read_text(encoding="utf-8")
    if args.declared:
        if args.diagnostics_dir is not None:
            parser.error("--declared reports the manifest as it is; it cannot add diagnostics")
        print(declared_option(contents))
    else:
        print(applied_option(contents, args.command, args.diagnostics_dir))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
