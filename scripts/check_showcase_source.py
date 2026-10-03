#!/usr/bin/env python3
"""Reproduce core native outputs from the exact source ZIP offered for download."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import zipfile

sys.dont_write_bytecode = True

from showcase_contract.site import ContractError, Site, canonical_json, load_json, relative_path
from showcase_build.manifest import roots


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def extract_source(site: Path, destination: Path) -> dict:
    manifest_path = site / "downloads/source-manifest.json"
    manifest = load_json(manifest_path)
    build = load_json(site / "build.json")
    if manifest.get("schemaVersion") != "cjdoc.showcase-source/1":
        raise ContractError("unsupported downloaded source manifest")
    for key in ("repository", "revision"):
        if manifest.get(key) != build["source"][key]:
            raise ContractError("source download provenance differs from the final site")
    archive = site / "downloads/pocketkit-source.zip"
    if digest(archive) != build["sourceDownload"]["sha256"]:
        raise ContractError("source download bytes differ from build provenance")
    if destination.exists():
        raise ContractError("source extraction requires a new directory")
    expected = set(manifest["files"]) | {"source.json"}
    with zipfile.ZipFile(archive) as download:
        members = download.infolist()
        names = [relative_path(item.filename) for item in members]
        if set(names) != expected or len(names) != len(set(names)):
            raise ContractError("source archive inventory mismatch or duplicate paths")
        if len(names) != len({name.casefold() for name in names}):
            raise ContractError("case-colliding source archive paths")
        if sum(item.file_size for item in members) > 64 * 1024 * 1024:
            raise ContractError("source archive exceeds the extraction budget")
        for item in members:
            mode = item.external_attr >> 16
            if item.is_dir() or item.flag_bits & 1 or stat.S_IFMT(mode) not in (0, stat.S_IFREG):
                raise ContractError("source archive contains an unsafe entry")
            value = download.read(item)
            if item.filename == "source.json":
                if value != manifest_path.read_bytes():
                    raise ContractError("source archive root metadata mismatch")
            elif hashlib.sha256(value).hexdigest() != manifest["files"][item.filename]:
                raise ContractError("source archive input digest mismatch")
            target = destination / item.filename
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(value)
    return manifest


def result_identity(path: Path) -> dict:
    value = load_json(path)
    return {"schemaVersion": value["schemaVersion"], "mode": value["mode"], "summary": value["summary"],
            "results": [{key: result[key] for key in
                         ("id", "symbolId", "qualifiedName", "title", "status", "exitCode", "message")}
                        for result in value["results"]]}


def compare_outputs(site: Path, generated: Path) -> list[dict]:
    comparisons = []
    native_files = ("docs.json", "api-surface.json", "coverage.json", "quality.json")
    for locale in ("zh-CN", "en"):
        documents = roots(site, locale)
        for version in ("demo-v1", "demo-v2", "diagnostics"):
            actual = generated / locale / version / "html"
            published = documents[version]
            files = ["machine/" + name for name in native_files]
            files += ["navigation-index.json", "symbol-index.json", "search-index.json", "llms.txt", "llms-full.txt"]
            files += [path.relative_to(actual).as_posix() for path in sorted((actual / "machine/markdown").rglob("*")) if path.is_file()]
            for name in files:
                if not (published / name).is_file() or (actual / name).read_bytes() != (published / name).read_bytes():
                    raise ContractError(f"source reproduction differs from published native output: {locale}/{version}/{name}")
            if result_identity(actual / "doctest/results.json") != result_identity(published / "doctest/results.json"):
                raise ContractError("source reproduction doctest identities/statuses differ")
            comparisons.append({"locale": locale, "version": version, "exactFiles": len(files),
                                "doctest": "actual identities, statuses and exit codes match; durations are measured independently"})
        if (generated / locale / "api-diff.json").read_bytes() != (documents["demo-v2"] / "machine/api-diff.json").read_bytes():
            raise ContractError("reproduced native API diff differs")
    return comparisons


def check(site: Path, binary: Path, evidence: Path) -> dict:
    site, binary, evidence = site.resolve(), binary.resolve(), evidence.resolve()
    if evidence.is_relative_to(site) or site.is_relative_to(evidence):
        raise ContractError("source evidence must be outside the immutable final site")
    if evidence.exists():
        raise ContractError("source evidence destination must be new")
    before = Site(site).digest()
    metadata = load_json(site / "build.json")
    if digest(binary) != metadata["tools"]["cjdocSha256"]:
        raise ContractError("source reproduction requires the exact generating native executable")
    evidence.parent.mkdir(parents=True, exist_ok=True)
    log = evidence.with_suffix(".log")
    with tempfile.TemporaryDirectory(prefix="cjdoc-source-reproduction-") as temporary:
        work = Path(temporary)
        source = work / "source"
        manifest = extract_source(site, source)
        command = [sys.executable, str(source / "examples/pocketkit/reproduce.py"), "--cjdoc", str(binary),
                   "--output", str(work / "generated"), "--locale", "both"]
        with log.open("x", encoding="utf-8") as output:
            subprocess.run(command, cwd=source, env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
                           stdout=output, stderr=subprocess.STDOUT, check=True, timeout=900)
        comparisons = compare_outputs(site, work / "generated")
    if Site(site).digest() != before:
        raise ContractError("final site changed during source reproduction")
    if digest(binary) != metadata["tools"]["cjdocSha256"]:
        raise ContractError("native executable changed during source reproduction")
    report = {"schemaVersion": "cjdoc.showcase-reproduction/1", "status": "passed",
              "revision": manifest["revision"], "siteSha256": before,
              "sourceArchiveSha256": digest(site / "downloads/pocketkit-source.zip"),
              "executableSha256": digest(binary), "command": manifest["reproduce"],
              "comparisons": comparisons, "logSha256": digest(log)}
    evidence.write_bytes(canonical_json(report))
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--site", type=Path, required=True)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    args = parser.parse_args()
    check(args.site, args.binary, args.evidence)
    print("Downloaded source reproduced the published native core artifacts and results.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"source reproduction failed: {error}", file=sys.stderr)
        raise SystemExit(1)
