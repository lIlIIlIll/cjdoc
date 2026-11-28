#!/usr/bin/env python3
"""Prove [lint] severity precedence, numeric CLI parsing and cfg diagnostics.

Runs the installed executable only. Three independently observable behaviors:

* #228: the trivial placeholder rules (CJDOC3047/3048/3049) follow `[lint]`
  `severity`, per-rule overrides and profile selection, and unknown rule keys
  still fail.
* #233: the four numeric options reject every non-decimal spelling with a
  message that names the option, while the existing range messages stay.
* #235: CJDOC1019 distinguishes a missing built-in value from an undefined
  condition and from malformed syntax, explicit `--cfg` still selects, and a
  non-host `os` value cannot be combined with `--check-examples`.

No repository checkout is modified; every fixture lives under --workdir.
"""
from __future__ import annotations

import argparse
import json
import os
import platform
import re
import subprocess
from pathlib import Path

DIAGNOSTIC = re.compile(r"^(warning|error)\[(CJDOC\d+)\]: (.*)$", re.MULTILINE)
TRIVIAL_RULES = {
    "trivial-summary": "CJDOC3047",
    "trivial-param-description": "CJDOC3048",
    "trivial-return-description": "CJDOC3049",
}
NUMERIC_OPTIONS = ("--jobs", "--max-doc-ir-mib", "--min-symbol-coverage",
                   "--min-parameter-coverage")
INVALID_INTEGERS = ("abc", "1.5", "", "0x10")

MANIFEST = '''[package]
cjc-version = "1.2.0"
name = "cli_diagnostics"
version = "0.1.0"
output-type = "static"
'''

QUALITY_SOURCE = '''package cli_diagnostics

/**
 * A marker with no state.
 *
 * Use it when an API needs to carry only the presence of a value.
 *
 * @example Create a marker.
 * ```cangjie
 * let _ = Marker()
 * println("created")
 * ```
 * ```output
 * created
 * ```
 */
public struct Marker {}

/**
 * API: echo.
 *
 * Preserves the marker supplied by the caller.
 *
 * @param value parameter value.
 * @return return Marker.
 * @example Pass through a marker.
 * ```cangjie
 * let _ = echo(Marker())
 * println("echoed")
 * ```
 * ```output
 * echoed
 * ```
 */
public func echo(value: Marker): Marker { value }
'''

CFG_SOURCE = '''package cli_diagnostics

/** Common API. */
public func common(): Int64 { 1 }

/** Linux API. */
@When[os == "Linux"]
public func linuxOnly(): Int64 { 2 }

/** Host architecture API. */
@When[arch == "__ARCH__"]
public func archHost(): Int64 { 3 }

/** Debug API. */
@When[debug]
public func debugOnly(): Int64 { 4 }

/** Feature API. */
@When[feature == "extra"]
public func featureOnly(): Int64 { 5 }

/** Undefined condition API. */
@When[missing]
public func missingCondition(): Int64 { 6 }
'''


def non_host_os() -> str:
    system = platform.system()
    if system == "Windows":
        return "Linux"
    if system == "Darwin":
        return "Windows"
    return "Windows"


def host_arch() -> str:
    machine = platform.machine().lower()
    if machine in ("x86_64", "amd64"):
        return "x86_64"
    if machine in ("aarch64", "arm64"):
        return "aarch64"
    return "arm"


class Runner:
    def __init__(self, binary: Path, root: Path):
        self.binary = binary
        self.root = root
        self.calls = 0

    def run(self, *args: str, expected: int | None = 0) -> subprocess.CompletedProcess[str]:
        self.calls += 1
        result = subprocess.run([str(self.binary), *args], capture_output=True,
                                text=True, encoding="utf-8", timeout=300)
        (self.root / f"command-{self.calls}.log").write_text(
            result.stdout + result.stderr, encoding="utf-8")
        if expected is not None and result.returncode != expected:
            raise AssertionError(
                f"{args} exited {result.returncode}, expected {expected}:\n{result.stderr}")
        return result

    def project(self, label: str, source: str, config: str | None = None) -> Path:
        root = self.root / label
        (root / "src").mkdir(parents=True)
        (root / "cjpm.toml").write_text(MANIFEST, encoding="utf-8")
        (root / "src" / "api.cj").write_text(source, encoding="utf-8")
        if config is not None:
            (root / "cjdoc.toml").write_text(config, encoding="utf-8")
        elif (root / "cjdoc.toml").exists():
            (root / "cjdoc.toml").unlink()
        return root

    def check(self, project: Path, *extra: str, expected: int = 0, semantic: str = "source"):
        worker = os.environ.get("CJDOC_CHIR_WORKER") if semantic == "chir" else None
        backend_options = ("--chir-worker", worker) if worker else ()
        return self.run("check", "--project", str(project), "--semantic", semantic,
                        "--no-cache", *backend_options, *extra, expected=expected)

    def generate(self, project: Path, *extra: str) -> dict:
        result = self.run("generate", "--project", str(project), "--semantic", "source",
                          "--format", "json", "--stdout", "--no-cache",
                          "--lint-profile", "off", *extra)
        return json.loads(result.stdout)


def diagnostics(result: subprocess.CompletedProcess[str]) -> list[tuple[str, str, str]]:
    return DIAGNOSTIC.findall(result.stderr)


def lint_matrix(runner: Runner) -> None:
    project = runner.project("lint-matrix", QUALITY_SOURCE)
    for profile in ("standard", "strict"):
        for rule, code in TRIVIAL_RULES.items():
            for level in ("off", "warning", "error"):
                config = f'[lint]\n{rule} = "{level}"\n'
                (project / "cjdoc.toml").write_text(config, encoding="utf-8")
                result = runner.check(project, "--lint-profile", profile,
                                      expected=1 if level == "error" else 0)
                found = [(severity, found_code) for severity, found_code, _ in diagnostics(result)
                         if found_code == code]
                if level == "off":
                    assert not found, (profile, rule, found)
                else:
                    assert found == [(level, code)], (profile, rule, level, found)
                if level == "warning":
                    denied = runner.check(project, "--lint-profile", profile,
                                          "--deny-warnings", expected=1)
                    assert ("warning", code) in [(s, c) for s, c, _ in diagnostics(denied)], (
                        profile, rule, denied.stderr)

    (project / "cjdoc.toml").write_text('[lint]\nseverity = "off"\n', encoding="utf-8")
    global_off = runner.check(project, "--lint-profile", "standard", "--deny-warnings", expected=0)
    assert not [code for _, code, _ in diagnostics(global_off) if code in TRIVIAL_RULES.values()]

    (project / "cjdoc.toml").write_text(
        '[lint]\nseverity = "off"\ntrivial-summary = "error"\n', encoding="utf-8")
    override = runner.check(project, "--lint-profile", "strict", expected=1)
    codes = [code for _, code, _ in diagnostics(override)]
    assert ("error", "CJDOC3047") in [(s, c) for s, c, _ in diagnostics(override)], override.stderr
    assert "CJDOC3048" not in codes and "CJDOC3049" not in codes, codes

    (project / "cjdoc.toml").write_text(
        '[lint]\ntrivial-param-description = "off"\n', encoding="utf-8")
    per_rule_off = runner.check(project, "--lint-profile", "standard", expected=0)
    codes = [code for _, code, _ in diagnostics(per_rule_off)]
    assert "CJDOC3048" not in codes and "CJDOC3047" in codes and "CJDOC3049" in codes, codes

    # Enable all the usual warnings except the three named rules. This
    # project must pass even if the caller does not turn off the lint profile.
    config = '[lint]\n' + ''.join(f'{rule} = "off"\n' for rule in TRIVIAL_RULES)
    original = runner.project("lint-deny-warnings", QUALITY_SOURCE)
    only_trivial = runner.check(original, "--lint-profile", "standard", "--deny-warnings",
                                expected=1, semantic="chir")
    assert {code for _, code, _ in diagnostics(only_trivial)} == set(TRIVIAL_RULES.values()), (
        only_trivial.stderr)
    (original / "cjdoc.toml").write_text(config, encoding="utf-8")
    allowed = runner.check(original, "--lint-profile", "standard", "--deny-warnings", semantic="chir")
    assert not diagnostics(allowed), allowed.stderr

    incomplete = QUALITY_SOURCE.replace(" * Preserves the marker supplied by the caller.\n *\n", "")
    other_warning = runner.project("lint-deny-other", incomplete, config)
    denied = runner.check(other_warning, "--lint-profile", "standard", "--deny-warnings",
                          expected=1, semantic="chir")
    assert {code for _, code, _ in diagnostics(denied)} == {"CJDOC3036"}, denied.stderr

    (project / "cjdoc.toml").write_text('[lint]\ntrivial-summaries = "off"\n',
                                        encoding="utf-8")
    unknown = runner.check(project, "--lint-profile", "standard", expected=2)
    assert "unknown [lint] setting 'trivial-summaries'" in unknown.stderr, unknown.stderr


def numeric_messages(runner: Runner) -> None:
    project = runner.project("numeric", QUALITY_SOURCE)
    for option in NUMERIC_OPTIONS:
        for value in INVALID_INTEGERS:
            result = runner.check(project, option, value, expected=2)
            first = result.stderr.splitlines()[0]
            assert f"{option} must be an integer" in first, (option, value, first)
            assert "convert failed" not in result.stderr, (option, value, result.stderr)
    for option, value, message in (
            ("--jobs", "0", "--jobs must be in 1..64"),
            ("--max-doc-ir-mib", "0", "max-doc-ir-mib must be in 1..64"),
            ("--min-symbol-coverage", "101", "coverage thresholds must be in 0..100"),
            ("--min-parameter-coverage", "-1", "coverage thresholds must be in 0..100")):
        result = runner.check(project, option, value, expected=2)
        assert message in result.stderr, (option, value, result.stderr)


def declarations(payload: dict) -> set[str]:
    return {entry["name"] for entry in payload.get("declarations", [])}


def cfg_diagnostics(payload: dict) -> list[str]:
    return [entry["message"] for entry in payload.get("diagnostics", [])
            if entry["code"] == "CJDOC1019"]


def cfg_selection(runner: Runner) -> None:
    project = runner.project("cfg", CFG_SOURCE.replace("__ARCH__", host_arch()))
    default = runner.generate(project)
    names = declarations(default)
    assert {"linuxOnly", "archHost", "debugOnly"} & names == set(), names
    messages = "\n".join(cfg_diagnostics(default))
    for name in ("os", "arch", "debug"):
        assert f"no {name} condition value was provided" in messages, messages
    assert "available values: Linux, Windows, macOS, iOS" in messages, messages
    assert "undefined condition 'missing'" in messages, messages
    assert default["status"] == "partial", default["status"]

    linux = runner.generate(project, "--cfg", "os=Linux")
    assert "linuxOnly" in declarations(linux) and "archHost" not in declarations(linux)
    assert "no arch condition value was provided" in "\n".join(cfg_diagnostics(linux))

    arch = runner.generate(project, "--cfg", f"arch={host_arch()}")
    assert "archHost" in declarations(arch) and "linuxOnly" not in declarations(arch)
    other_arch = "aarch64" if host_arch() == "x86_64" else "x86_64"
    incompatible = runner.generate(project, "--cfg", f"arch={other_arch}")
    assert "archHost" not in declarations(incompatible)
    assert not any("arch condition value" in message for message in cfg_diagnostics(incompatible))

    enabled = runner.generate(project, "--cfg", "debug=true")
    assert "debugOnly" in declarations(enabled)
    disabled = runner.generate(project, "--cfg", "debug=false")
    assert "debugOnly" not in declarations(disabled)

    windows = runner.generate(project, "--cfg", "os=Windows")
    assert "linuxOnly" not in declarations(windows)

    # In both forms the branch containing `os` is already known, so only the
    # remaining undefined condition can affect selection.
    for debug, inner, outer in (("false", "&&", "||"), ("true", "||", "&&")):
        short_circuit = runner.project(f"cfg-short-circuit-{debug}", f"""package cli_diagnostics

@When[(os == "Linux" {inner} debug) {outer} feature == "extra"]
public func available(): Int64 {{ 1 }}
""")
        unresolved = runner.generate(short_circuit, "--cfg", f"debug={debug}")
        messages = cfg_diagnostics(unresolved)
        assert len(messages) == 1 and "undefined condition 'feature'" in messages[0], messages
        assert "available" not in declarations(unresolved)
        selected = runner.generate(short_circuit, "--cfg", f"debug={debug}",
                                   "--cfg", "feature=extra")
        assert "available" in declarations(selected)
        assert not cfg_diagnostics(selected)

    feature = runner.generate(project, "--cfg", "feature=extra")
    assert "featureOnly" in declarations(feature)
    undefined_selected = runner.generate(project, "--cfg", "missing=true")
    assert "missingCondition" in declarations(undefined_selected)

    conflict = runner.run("generate", "--project", str(project), "--semantic", "source",
                          "--format", "json", "--stdout", "--no-cache",
                          "--cfg", "os=Linux", "--cfg", "os=Windows", expected=2)
    assert "conflicting cfg values for 'os'" in conflict.stderr, conflict.stderr

    example = runner.project("cfg-examples", CFG_SOURCE.replace("__ARCH__", host_arch()).replace(
        "/** Common API. */\npublic func common",
        "/**\n * Common API.\n * @example Basic\n * ```cangjie\n"
        " * let result = common()\n * ```\n */\npublic func common"))
    mismatch = runner.check(example, "--check-examples", "--cfg",
                            f"os={non_host_os()}", expected=1)
    assert "does not match compiler target" in mismatch.stderr, mismatch.stderr
    assert ("error", "CJDOC3031") in [(s, c) for s, c, _ in diagnostics(mismatch)], mismatch.stderr


def external_index_diagnostics(runner: Runner) -> None:
    project = runner.project("external-index", QUALITY_SOURCE)
    index = project / "partner-symbols.json"
    index.write_text(json.dumps({
        "schemaVersion": "cjdoc.symbol-index/1",
        "symbols": [
            {"qualifiedName": "cli_diagnostics.echo", "href": "echo.html"},
            {"qualifiedName": "cli_diagnostics.BadType", "href": 42},
            {"qualifiedName": "cli_diagnostics.BadPath", "href": "entry.html\n#bad"},
        ],
    }), encoding="utf-8")
    (project / "cjdoc.toml").write_text(
        '[external-docs.partner]\n'
        f'index = "{index.as_posix()}"\n'
        'base-url = "https://docs.example.test/api"\n', encoding="utf-8")
    payload = runner.generate(project)
    warnings = {entry["message"] for entry in payload["diagnostics"] if entry["code"] == "CJDOC2313"}
    assert warnings == {
        f"external documentation index 'partner-symbols.json': invalid href for record 'cli_diagnostics.{name}'"
        for name in ("BadType", "BadPath")
    }, warnings


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--workdir", type=Path, required=True)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    args.repo.resolve(strict=True)
    args.workdir.mkdir(parents=True, exist_ok=False)
    runner = Runner(binary, args.workdir.resolve())
    lint_matrix(runner)
    numeric_messages(runner)
    cfg_selection(runner)
    external_index_diagnostics(runner)
    print(f"CLI diagnostics: {runner.calls} checks passed")


if __name__ == "__main__":
    main()
