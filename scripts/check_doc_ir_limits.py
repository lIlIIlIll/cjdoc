#!/usr/bin/env python3
"""Exercise documented Doc IR size limits through the installed CLI."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess

MIB = 1024 * 1024


def check(binary: Path, workdir: Path) -> None:
    workdir.mkdir(parents=True, exist_ok=False)
    calls = 0

    def run(*args: str, expected: int = 0) -> subprocess.CompletedProcess[str]:
        nonlocal calls
        calls += 1
        result = subprocess.run([str(binary), *args], text=True, encoding="utf-8",
                                capture_output=True, timeout=180)
        (workdir / f"command-{calls}.stderr").write_text(result.stderr, encoding="utf-8")
        if result.returncode != expected:
            raise AssertionError(f"command {calls} returned {result.returncode}, expected {expected}: {result.stderr}")
        return result

    project = workdir / "project"
    (project / "src").mkdir(parents=True)
    (project / "cjpm.toml").write_text(
        '[package]\nname = "limits_fixture"\nversion = "1.0.0"\ncjc-version = "1.2.0"\n', encoding="utf-8")
    source = project / "src" / "api.cj"
    source.write_text('package limits_fixture\n/** An API. */\npublic func api(): Int64 { 1 }\n', encoding="utf-8")
    generate = ("generate", "--project", str(project), "--format", "json", "--stdout",
                "--no-cache", "--lint-profile", "off")
    sample = run(*generate).stdout.encode("utf-8")
    padded = workdir / "padded.json"
    with padded.open("wb") as stream:
        stream.write(sample)
        remaining = 64 * MIB - len(sample)
        while remaining:
            count = min(remaining, MIB)
            stream.write(b" " * count)
            remaining -= count
    render = ("render", "--input", str(padded), "--format", "json", "--stdout")
    assert json.loads(run(*render).stdout)["project"]["name"] == "limits_fixture"
    assert json.loads(run(*render, "--max-doc-ir-mib", "64").stdout)["project"]["name"] == "limits_fixture"
    assert "33554432" in run(*render, "--max-doc-ir-mib", "32", expected=2).stderr
    with padded.open("ab") as stream:
        stream.write(b" ")
    assert "67108864" in run(*render, expected=2).stderr
    padded.unlink()

    source.write_text('package limits_fixture\n/** ' + "x" * (600 * 1024) +
                      ' */\npublic func api(): Int64 { 1 }\n', encoding="utf-8")
    config = project / "cjdoc.toml"
    config.write_text("[limits]\nmax-doc-ir-mib = 1\n", encoding="utf-8")
    limited = json.loads(run(*generate).stdout)
    assert limited["project"]["name"] == "resource-limited"
    assert any(item["code"] == "CJDOC3027" for item in limited["diagnostics"])
    run("check", "--project", str(project), "--no-cache", "--lint-profile", "off", "--deny-warnings", expected=1)
    overridden = run(*generate, "--max-doc-ir-mib", "64")
    assert len(overridden.stdout.encode("utf-8")) > MIB
    assert json.loads(overridden.stdout)["project"]["name"] == "limits_fixture"
    config.unlink()
    assert run(*generate).stdout == overridden.stdout

    for value in ("0", "65", "-1", "invalid", "9223372036854775808"):
        run(*generate, "--max-doc-ir-mib", value, expected=2)
    run(*generate, "--max-doc-ir-mib", expected=2)
    run("diff", "old.json", "new.json", "--max-doc-ir-mib", "32", expected=2)
    config.write_text("[limits]\nmax-doc-ir-mib = 65\n", encoding="utf-8")
    run(*generate, "--max-doc-ir-mib", "64", expected=2)
    for header in ("[[limits]]", "[[ limits ]]", '[["limits"]]', "[limits.extra]"):
        config.write_text(header + "\nmax-doc-ir-mib = 1\n", encoding="utf-8")
        run(*generate, expected=2)
        run(*generate, "--max-doc-ir-mib", "64", expected=2)
    for assignment in ("limits.max-doc-ir-mib = 1", "limits . max-doc-ir-mib = 1",
                       '"limits".max-doc-ir-mib = 1', "'limits' . max-doc-ir-mib = 1",
                       r'"lim\u0069ts".max-doc-ir-mib = 1',
                       "limits = { max-doc-ir-mib = 1 }", "'limits' = { max-doc-ir-mib = 1 }",
                       "limits = 1"):
        config.write_text(assignment + "\n", encoding="utf-8")
        assert "[limits]" in run(*generate, expected=2).stderr
        assert "[limits]" in run(*generate, "--max-doc-ir-mib", "64", expected=2).stderr
    print(f"Doc IR limits: {calls} CLI checks passed")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--workdir", required=True, type=Path)
    args = parser.parse_args()
    check(args.binary.resolve(strict=True), args.workdir)


if __name__ == "__main__":
    main()
