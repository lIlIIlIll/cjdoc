#!/usr/bin/env python3
"""Reproduce PocketKit's core pages with the same native CLI used by Pages.

Only the fixed dependency index is derived in the source tree. Managed TOML
files are never rewritten. Existing output directories are never removed.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

VERSIONS = ("demo-v1", "demo-v2")
LOCALES = ("zh-CN", "en")
FORMATS = ("html", "json", "markdown", "api-surface", "coverage")


def run(command: list[str], cwd: Path, *, output: Path | None = None) -> None:
    print("+ " + " ".join(command), flush=True)
    if output is None:
        subprocess.run(command, cwd=cwd, check=True)
    else:
        with output.open("x", encoding="utf-8") as stream:
            subprocess.run(command, cwd=cwd, stdout=stream, check=True, text=True)


def generate(binary: Path, project: Path, output: Path, *, locale: str,
             version: str, repository: str | None = None,
             revision: str | None = None, repository_root: Path | None = None) -> Path:
    if output.exists():
        raise FileExistsError(f"refusing to replace generated output: {output}")
    command = [str(binary), "generate", "--project", str(project)]
    for name in FORMATS:
        command += ["--format", name]
    command += ["--output", str(output), "--locale", locale,
                "--doc-version", version, "--agent-full", "--no-cache"]
    if repository is not None:
        if not revision or repository_root is None:
            raise ValueError("source links require a revision and repository root")
        command += ["--repository-url", repository,
                    "--repository-revision", revision,
                    "--repository-root", str(repository_root)]
    run(command, project)
    return output


def assemble(output: Path) -> Path:
    """Copy native machine payloads alongside their own HTML, without changing IDs."""
    root = output / "html"
    machine = root / "machine"
    machine.mkdir()
    for source, name in ((output / "docs.json", "docs.json"),
                         (output / "api-surface/api-surface.json", "api-surface.json"),
                         (output / "coverage/coverage.json", "coverage.json")):
        shutil.copyfile(source, machine / name)
    shutil.copytree(output / "markdown", machine / "markdown")
    results = output / "doctest/results.json"
    if results.is_file():
        (root / "doctest").mkdir()
        shutil.copyfile(results, root / "doctest/results.json")
        page = root / "validation.html"
        content = page.read_text(encoding="utf-8")
        old = 'href="../doctest/results.json"'
        if old not in content:
            raise ValueError("native validation page has no expected doctest evidence link")
        page.write_text(content.replace(old, 'href="doctest/results.json"'), encoding="utf-8")
    return root


def build(binary: Path, source: Path, output: Path, *, locales: tuple[str, ...] = LOCALES,
          repository: str | None = None, revision: str | None = None,
          repository_root: Path | None = None) -> dict:
    binary, source, output = binary.resolve(), source.resolve(), output.resolve()
    if not binary.is_file():
        raise FileNotFoundError(binary)
    if output.exists():
        raise FileExistsError(f"output must not already exist: {output}")
    if any(locale not in LOCALES for locale in locales) or not locales:
        raise ValueError("unsupported locale selection")
    managed = sorted(source.rglob("cjdoc.toml")) + sorted(source.rglob("cjpm.toml"))
    before = {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in managed}
    output.mkdir(parents=True)
    options = dict(repository=repository, revision=revision, repository_root=repository_root)
    support = generate(binary, source / "support-v1", output / "support", locale="en",
                       version="support-v1", **options)
    index = support / "html/symbol-index.json"
    data = json.loads(index.read_text(encoding="utf-8"))
    if data.get("schemaVersion") != "cjdoc.symbol-index/1" or data.get("version") != "support-v1":
        raise ValueError("independent dependency index has the wrong schema/version")
    for version in VERSIONS:
        shutil.copyfile(index, source / version / "docs/support-symbol-index.json")
    result = {"support": support, "locales": {}}
    for locale in locales:
        directory = output / locale
        directory.mkdir()
        generated = {}
        for version in VERSIONS:
            generated[version] = generate(binary, source / version, directory / version,
                                          locale=locale, version=version, **options)
            assemble(generated[version])
        diff = directory / "api-diff.json"
        run([str(binary), "diff", "--baseline",
             str(generated["demo-v1"] / "api-surface/api-surface.json"), "--current",
             str(generated["demo-v2"] / "api-surface/api-surface.json"), "--format", "json"],
            source, output=diff)
        composed = directory / "composed"
        run([str(binary), "versions", "compose", "--output", str(composed),
             "--version", "demo-v1=" + str(generated["demo-v1"] / "html"),
             "--version", "demo-v2=" + str(generated["demo-v2"] / "html"),
             "--diff", "demo-v2=" + str(diff), "--latest", "demo-v2"], source)
        versions = json.loads((composed / "versions.json").read_text(encoding="utf-8"))
        if versions.get("schemaVersion") != "cjdoc.versions/1":
            raise ValueError("unsupported native versions manifest")
        records = {entry["id"]: entry for entry in versions["versions"]}
        if set(records) != set(VERSIONS):
            raise ValueError("native composition did not retain both example snapshots")
        roots = {}
        for version in VERSIONS:
            relative = Path(records[version]["basePath"])
            if relative.is_absolute() or ".." in relative.parts:
                raise ValueError("unsafe native version base path")
            root = composed / relative
            # Copy after compose: support-v1 must not acquire PocketKit's version selector.
            shutil.copytree(support / "html", root / "dependencies/support-v1")
            roots[version] = root
        diagnostics = generate(binary, source / "diagnostics", directory / "diagnostics",
                               locale=locale, version="diagnostics", **options)
        assemble(diagnostics)
        result["locales"][locale] = dict(generated=generated, composed=composed,
                                         roots=roots, diff=diff, diagnostics=diagnostics)
    after = {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in managed}
    if before != after:
        raise ValueError("managed example configuration changed during generation")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cjdoc", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--locale", choices=(*LOCALES, "both"), default="both")
    args = parser.parse_args()
    source = Path(__file__).resolve().parent
    repository_root = source.parent.parent
    metadata = repository_root / "source.json"
    provenance = json.loads(metadata.read_text(encoding="utf-8")) if metadata.is_file() else {}
    build(args.cjdoc, source, args.output,
          locales=LOCALES if args.locale == "both" else (args.locale,),
          repository=provenance.get("repository"), revision=provenance.get("revision"),
          repository_root=repository_root if provenance else None)
    print("Generated core HTML, native reports, machine outputs and version composition.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"reproduction failed: {error}", file=sys.stderr)
        raise SystemExit(1)
