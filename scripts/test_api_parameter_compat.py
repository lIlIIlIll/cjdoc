#!/usr/bin/env python3
"""Exercise the API diff gate on compiler-accepted old and new declarations."""

import argparse
import json
from pathlib import Path
import shutil
import subprocess


MANIFEST = '''[package]
cjc-version = "1.2.0"
name = "api_param_probe"
version = "1.0.0"
output-type = "static"
'''


def execute(args, *, expected, cwd=None):
    result = subprocess.run(args, cwd=cwd, capture_output=True, encoding="utf-8", timeout=120)
    assert result.returncode == expected, (args, result.returncode, result.stdout, result.stderr)
    return result


def source_fixture(root, label, source_body):
    project = root / label
    source = project / "src" / "api.cj"
    source.parent.mkdir(parents=True)
    (project / "cjpm.toml").write_text(MANIFEST, encoding="utf-8")
    source.write_text(f"package api_param_probe\n{source_body}\n", encoding="utf-8")
    return project


def fixture(root, label, parameters, returns="Int64"):
    result = "1" if returns == "Int64" else '"value"'
    return source_fixture(root, label, "/** Accept a value. */\n"
                          f"public func accept({parameters}): {returns} {{ {result} }}")


def point_fixture(root, label, parameters):
    return source_fixture(root, label, "public class Point {\n"
                          f"    public Point({parameters}) {{}}\n}}")


def surface(binary, project, mode):
    result = execute([binary, "generate", "--project", project, "--semantic", mode,
                      "--format", "api-surface", "--stdout", "--no-cache", "--lint-profile", "off"],
                     expected=0)
    path = project.parent / f"{project.name}-{mode}.json"
    path.write_text(result.stdout, encoding="utf-8")
    return path


def compare(binary, baseline, current, expected, evidence, *, comparison_state=None):
    for deny, status in (("--deny-breaking-api", int(expected == "breaking")),
                         ("--deny-potentially-breaking-api", int(expected == "potentially-breaking"))):
        result = execute([binary, "diff", "--baseline", baseline, "--current", current,
                          "--format", "json", deny], expected=status)
        report = json.loads(result.stdout)
        entries = [entry for entry in report["entries"] if entry["classification"] != "unchanged"]
        assert len(entries) == 1 and entries[0]["classification"] == expected, report
        assert evidence in {item["field"] for item in entries[0]["evidence"]}, report
        if comparison_state is not None:
            assert report["comparisonState"] == comparison_state, report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    root = args.output.resolve()
    named = "value!: Int64 = 1"
    extra = ", count!: Int64 = (1 + 2)"
    projects = {
        "old": fixture(root, "old", "value: Int64"),
        "added": fixture(root, "added", "value: Int64" + extra),
        "type": fixture(root, "type", "value: String" + extra),
        "named": fixture(root, "named", "value!: Int64" + extra),
        "return": fixture(root, "return", "value: Int64" + extra, returns="String"),
        "old-named": fixture(root, "old-named", named),
        "default": fixture(root, "default", "value!: Int64 = 2" + extra),
        "default-removed": fixture(root, "default-removed", "value!: Int64" + extra),
        "renamed": fixture(root, "renamed", "number!: Int64 = 1" + extra),
        "old-point": point_fixture(root, "old-point", "value: Int64"),
        "added-point": point_fixture(root, "added-point", "value: Int64" + extra),
    }
    cjpm = shutil.which("cjpm")
    assert cjpm, "the native compatibility contrast requires cjpm"
    for case in ("old", "type"):
        execute([cjpm, "build", "--jobs", "1"], cwd=projects[case], expected=0)

    for mode in ("source", "chir"):
        paths = {case: surface(binary, project, mode) for case, project in projects.items()}
        resolved = mode == "chir"
        compare(binary, paths["old"], paths["added"], "additive", "parameters", comparison_state="resolved")
        compare(binary, paths["old-point"], paths["added-point"], "additive", "parameters")
        compare(binary, paths["old"], paths["type"], "breaking" if resolved else "potentially-breaking",
                "parameters[0].type" if resolved else "sourceApiSignature")
        compare(binary, paths["old"], paths["named"], "potentially-breaking", "sourceApiSignature")
        compare(binary, paths["old"], paths["return"], "breaking" if resolved else "potentially-breaking",
                "return" if resolved else "sourceApiSignature")
        compare(binary, paths["old-named"], paths["default"], "potentially-breaking", "parameters[0].default")
        compare(binary, paths["old-named"], paths["default-removed"], "breaking", "parameters[0].default")
        compare(binary, paths["old-named"], paths["renamed"], "potentially-breaking", "parameters[0].name")

    for case, expected in (("old", 0), ("type", 1)):
        with (projects[case] / "src" / "api.cj").open("a", encoding="utf-8") as source:
            source.write("public func oldCall(): Int64 { accept(1) }\n")
        result = execute([cjpm, "build", "--jobs", "1"], cwd=projects[case], expected=expected)
        if expected:
            assert "accept(1)" in result.stdout + result.stderr, result
    print("API diff optional-tail regression passed for source, CHIR, and native old-call compilation")


if __name__ == "__main__":
    main()
