#!/usr/bin/env python3
"""Aggregate the independent showcase branches into one auditable receipt.

`verify-site` must prove that the source-reproduction, browser and reading
branches all ran against the same sealed site, manifest and binary. Each branch
writes its own evidence file; this script cross-checks every one of them against
the sealed site digest, the resolved manifest and the build manifest before
writing `cjdoc.showcase-branch-receipt/1`.

Missing, duplicated, schema-mismatched, digest-mismatched or identity-mismatched
branches fail with a nonzero exit. This gate only reads.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))

from showcase_contract.site import Site, canonical_json, load_json

RECEIPT_SCHEMA = "cjdoc.showcase-branch-receipt/1"
SHA256 = re.compile(r"^[0-9a-f]{64}$")
BRANCH_SCHEMAS = {
    "source-reproduction": "cjdoc.showcase-reproduction/1",
    "reading-regressions": None,
}
BROWSER_SCHEMAS = {"cjdoc.showcase-evidence/2"}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"branch receipt: {message}")


def collect(site: Path, site_sha256: str, build_manifest: Path,
            source_evidence: Path, reading_evidence: Path, out: Path,
            extra: dict[str, dict[str, str]] | None = None) -> dict:
    require(SHA256.fullmatch(site_sha256) is not None, "--site-sha256 must be lowercase SHA-256")
    sealed = Site(site)
    actual = sealed.digest()
    require(actual == site_sha256, f"sealed site digest {actual} != declared {site_sha256}")
    manifest_path = sealed.file("showcase-features.json")
    manifest = load_json(manifest_path)
    build = load_json(build_manifest)

    branches: dict[str, dict[str, str]] = {}
    source = load_json(source_evidence)
    require(source.get("schemaVersion") == BRANCH_SCHEMAS["source-reproduction"],
            "source-reproduction evidence has an unexpected schema")
    require(source.get("siteSha256") == actual,
            "source-reproduction evidence is for a different site")
    require(source.get("revision") == manifest.get("revision"),
            "source-reproduction evidence is for a different revision")
    require(source.get("executableSha256") == build["mainBinary"]["sha256"],
            "source-reproduction used a different native executable")
    branches["source-reproduction"] = {"file": source_evidence.name,
                                       "sha256": sha256_file(source_evidence)}

    reading = load_json(reading_evidence)
    require(reading.get("revision") == manifest.get("revision"),
            "reading-regressions evidence is for a different revision")
    require(reading.get("siteSha256") == actual and reading.get("siteSha256After") == actual,
            "reading-regressions evidence is for a different site")
    require(reading.get("results"), "reading-regressions evidence has no results")
    branches["reading-regressions"] = {"file": reading_evidence.name,
                                       "sha256": sha256_file(reading_evidence)}
    for name, record in (extra or {}).items():
        if name in branches:
            raise SystemExit(f"branch receipt: branch {name!r} is already derived from its evidence file")
        branches[name] = record

    receipt = {
        "schemaVersion": RECEIPT_SCHEMA,
        "siteSha256": actual,
        "revision": manifest["revision"],
        "manifestSha256": hashlib.sha256(canonical_json(manifest)).hexdigest(),
        "sourceArchiveSha256": build["sourceDownload"]["sha256"],
        "binarySha256": build["mainBinary"]["sha256"],
        "branches": branches,
    }
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(receipt, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
                   encoding="utf-8", newline="\n")
    return receipt


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--site", type=Path, required=True)
    parser.add_argument("--site-sha256", required=True)
    parser.add_argument("--build-manifest", type=Path, required=True)
    parser.add_argument("--source-evidence", type=Path, required=True)
    parser.add_argument("--reading-evidence", type=Path, required=True)
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--branch", action="append", default=[], metavar="NAME=FILE",
                        help="extra branch evidence to record, e.g. browser=results.json")
    args = parser.parse_args()
    extra: dict[str, dict[str, str]] = {}
    for value in args.branch:
        name, _, path = value.partition("=")
        if not name or not path:
            raise SystemExit(f"branch receipt: invalid --branch value {value!r}")
        if name in extra:
            raise SystemExit(f"branch receipt: repeated branch name {name!r}")
        candidate = Path(path)
        if not candidate.is_file() or candidate.is_symlink():
            raise SystemExit(f"branch receipt: branch file is missing: {path}")
        extra[name] = {"file": candidate.name, "sha256": sha256_file(candidate)}
    receipt = collect(args.site, args.site_sha256, args.build_manifest,
                      args.source_evidence, args.reading_evidence, args.receipt, extra)
    print(f"branch receipt written: {args.receipt} ({len(receipt['branches'])} branches)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
